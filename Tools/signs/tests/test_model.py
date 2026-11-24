import time

import numpy as np
import torch

from signs.data import WordClipDataset, assign_splits, collate_spelling_batch, load_sources, references_in_split, SpellClipDataset, build_character_list
from signs.model import EncoderSettings, SignSpellModel, SignWordModel, count_parameters
from signs.training import greedy_ctc_decode, spelling_ctc_loss, edit_distance, spelling_scores
from synthetic_signs import WORD_TRAJECTORIES, make_spelling_dataset, make_word_dataset


def small_settings(**changes):
    return EncoderSettings(width=64, drop_path_rate=0.0, dropout_rate=0.0, **changes)


def random_batch(batch_size, frame_count, real_frame_counts, seed=0):
    generator = torch.Generator().manual_seed(seed)
    features = torch.randn(batch_size, frame_count, 117, generator=generator)
    features[:, :, 114:] = (torch.rand(batch_size, frame_count, 3, generator=generator) > 0.3).float()
    frame_mask = torch.zeros(batch_size, frame_count)
    for sample_number, real_frame_count in enumerate(real_frame_counts):
        frame_mask[sample_number, :real_frame_count] = 1.0
    return features * frame_mask.unsqueeze(-1), frame_mask


def test_parameter_counts_at_full_width():
    word_parameter_count = count_parameters(SignWordModel(EncoderSettings(), 250))
    spell_parameter_count = count_parameters(SignSpellModel(EncoderSettings(halve_frames_after_first_stage=True), 59))
    print(f"words: {word_parameter_count:,}  spelling: {spell_parameter_count:,}")
    assert 1_500_000 < word_parameter_count < 6_000_000
    assert 1_500_000 < spell_parameter_count < 6_000_000


def test_word_model_shapes_and_padding_does_not_change_scores():
    model = SignWordModel(small_settings(), word_count=7).eval()
    features, frame_mask = random_batch(3, 96, [96, 40, 5])
    with torch.no_grad():
        scores, description = model(features, frame_mask)
        assert scores.shape == (3, 7) and description.shape == (3, 64)
        padded_features = torch.cat([features, torch.zeros(3, 50, 117)], dim=1)
        padded_mask = torch.cat([frame_mask, torch.zeros(3, 50)], dim=1)
        more_padded_scores, more_padded_description = model(padded_features, padded_mask)
        # Garbage in padded frames must not matter either.
        garbage_features = features + (1 - frame_mask).unsqueeze(-1) * torch.randn_like(features) * 5
        garbage_scores, garbage_description = model(garbage_features, frame_mask)
    torch.testing.assert_close(more_padded_scores, scores, atol=1e-4, rtol=0)
    torch.testing.assert_close(more_padded_description, description, atol=1e-4, rtol=0)
    torch.testing.assert_close(garbage_scores, scores, atol=1e-4, rtol=0)


def test_spell_model_shapes_and_padding():
    model = SignSpellModel(small_settings(halve_frames_after_first_stage=True), character_count=5).eval()
    features, frame_mask = random_batch(2, 256, [256, 77])
    with torch.no_grad():
        log_probabilities, output_lengths = model(features, frame_mask)
        assert log_probabilities.shape == (2, 128, 6)
        assert output_lengths.tolist() == [128, 39]
        torch.testing.assert_close(log_probabilities.exp().sum(-1), torch.ones(2, 128))
        padded_log_probabilities, padded_lengths = model(
            torch.cat([features, torch.zeros(2, 40, 117)], 1), torch.cat([frame_mask, torch.zeros(2, 40)], 1)
        )
    torch.testing.assert_close(padded_log_probabilities[1, :39], log_probabilities[1, :39], atol=1e-4, rtol=0)
    assert padded_lengths.tolist() == [128, 39]


def test_motion_is_zero_where_a_hand_is_not_seen_and_at_padding():
    encoder = SignWordModel(small_settings(), 3).encoder
    features = torch.ones(1, 6, 117)
    features[0, :, 0] = torch.arange(6).float()  # right-hand number moving by 1 a frame
    features[0, :, 90] = torch.arange(6).float() * 2  # a body number moving by 2
    features[0, 3, 114] = 0.0  # right hand not seen in frame 3
    frame_mask = torch.tensor([[1, 1, 1, 1, 1, 0.0]])
    motion = encoder.motion_inputs(features * frame_mask.unsqueeze(-1), frame_mask)
    assert motion.shape == (1, 6, 345)
    lag_one_right_hand = motion[0, :, 117 + 0].tolist()
    assert lag_one_right_hand == [0, 1, 1, 0, 0, 0]  # frame 0 no history, frames 3 and 4 touch frame 3, frame 5 padded
    lag_two_body = motion[0, :, 117 + 114 + 90].tolist()
    assert lag_two_body == [0, 0, 4, 4, 4, 0]


def test_trace_on_fixed_shapes():
    word_model = SignWordModel(small_settings(), 4).eval()
    with torch.no_grad():
        traced = torch.jit.trace(word_model, (torch.zeros(1, 96, 117), torch.ones(1, 96)))
        features, frame_mask = random_batch(1, 96, [50])
        torch.testing.assert_close(traced(features, frame_mask)[0], word_model(features, frame_mask)[0])
    spell_model = SignSpellModel(small_settings(halve_frames_after_first_stage=True), 4).eval()
    with torch.no_grad():
        traced = torch.jit.trace(spell_model, (torch.zeros(1, 256, 117), torch.ones(1, 256)))
        features, frame_mask = random_batch(1, 256, [100])
        torch.testing.assert_close(traced(features, frame_mask)[0], spell_model(features, frame_mask)[0])


def test_word_model_overfits_five_synthetic_words(tmp_path):
    started_at = time.monotonic()
    torch.manual_seed(0)
    data_folder = make_word_dataset(tmp_path / "words", clips_per_word_per_signer=2, signer_count=4)
    sources = load_sources([str(data_folder)])
    sample_references, signer_splits = assign_splits(sources, seed=0, test_fraction=0.0, validation_fraction=0.0)
    dataset = WordClipDataset(sources, references_in_split(sample_references, "train"), list(WORD_TRAJECTORIES))
    features = torch.stack([dataset[sample_number][0] for sample_number in range(len(dataset))])
    frame_mask = torch.stack([dataset[sample_number][1] for sample_number in range(len(dataset))])
    word_numbers = torch.stack([dataset[sample_number][2] for sample_number in range(len(dataset))])
    assert len(dataset) == 40

    model = SignWordModel(small_settings(), len(WORD_TRAJECTORIES))
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3)
    for step in range(250):
        model.train()
        scores, description = model(features, frame_mask)
        loss = torch.nn.functional.cross_entropy(scores, word_numbers)
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        if step % 10 == 9:
            model.eval()
            with torch.no_grad():
                accuracy = (model(features, frame_mask)[0].argmax(1) == word_numbers).float().mean().item()
            if accuracy > 0.95:
                break
    assert accuracy > 0.95, f"training accuracy {accuracy}"
    assert time.monotonic() - started_at < 60


def test_spelling_ctc_loss_falls(tmp_path):
    torch.manual_seed(0)
    data_folder = make_spelling_dataset(tmp_path / "spell", phrases_per_signer=6, signer_count=3)
    sources = load_sources([str(data_folder)])
    sample_references, signer_splits = assign_splits(sources, seed=0, test_fraction=0.0, validation_fraction=0.0)
    training_references = references_in_split(sample_references, "train")
    character_list = build_character_list(training_references)
    dataset = SpellClipDataset(sources, training_references, character_list)
    features, frame_mask, joined_targets, target_lengths = collate_spelling_batch([dataset[number] for number in range(len(dataset))])

    model = SignSpellModel(small_settings(halve_frames_after_first_stage=True), len(character_list))
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-3)
    losses = []
    for step in range(60):
        log_probabilities, output_lengths = model(features, frame_mask)
        loss = spelling_ctc_loss(log_probabilities, output_lengths, joined_targets, target_lengths)
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        losses.append(loss.item())
    assert np.isfinite(losses).all()
    assert losses[-1] < 0.5 * losses[0], losses[:: max(1, len(losses) // 6)]


def test_ctc_helpers():
    # Outputs per frame: a a blank a b b -> "aab" with 1 = a, 2 = b.
    best_outputs = torch.tensor([[1, 1, 0, 1, 2, 2, 0]])
    log_probabilities = torch.nn.functional.one_hot(best_outputs, 3).float().log_softmax(-1)
    assert greedy_ctc_decode(log_probabilities, torch.tensor([6])) == [[1, 1, 2]]
    assert edit_distance("kitten", "sitting") == 3
    assert spelling_scores(10, 3) == {"character_error_rate": 0.3, "kaggle_score": 0.7}
