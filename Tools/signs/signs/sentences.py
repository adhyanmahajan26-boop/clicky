"""Runs of signs without rests, built from single-sign clips, for the sentence model (`SignSentencesASL` / `ISL`).

Fluent signers don't drop their hands between signs, and there is no openly licensed sentence-level data we may
ship, so the sentence model learns from sentences joined together here from isolated-sign clips:

1. Pick 1 to 6 clips (`choose_sign_count`: one sign about a quarter of the time, so the model still reads a lone
   sign well, 2 to 6 equally often otherwise). After the first, clips come from the same signer when the manifest
   names signers, else from any clip.
2. Cut each to its signing part (`signing_part`: from the first to the last frame with a wrist above the rest line,
   1.5 body sizes under the features' own centre, the wrist being the hand's own when the hand is seen, else the
   body pose's), so the hands never drop to rest between signs, as in fluent signing. About a fifth of the clips
   (`rest_join_share`) keep up to `short_rest_frames` of their resting frames at each end instead, since real
   signers do sometimes pause. Then, half the time, shave up to a fifth off each end, since in fluent signing one
   sign runs into the next. (Until round 6 clips were only trimmed of frames with no hand at all, which in INCLUDE
   kept the hands resting at the sides at both ends of every clip: every join had a rest.)
3. Bring every clip onto the first clip's body: move and scale it so its shoulder centre and body size (what
   `features.py` computes, in units where x and y are the same size) match the first clip's.
4. Join them with 3 to 10 in-between frames: a point seen at the end of one sign and the start of the next slides
   along a straight line (with the smaller of the two confidences); every other point is unseen there.
5. The whole sentence then gets the usual augmentations (`augment.py`) in training, then features.

A manifest row whose label is several signs with `|` between them (a real continuous clip, such as an ISL
sentence, "i|go|school") is used as it is:
for training when it's in the training split, for measuring when it's in validation or test.

**Numbers on built sentences are not numbers on real fluent signing.** Real signing changes each sign's shape and
path where it meets its neighbours (co-articulation), drops and merges movements, and uses space and the face in
ways joined clips never show. Treat the built-sentence word error rate as an upper bound on how well the model
does, and trust only real continuous clips (reported apart) for how it reads a person.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np
import torch
from torch.utils.data import Dataset

from .augment import AugmentSettings, augment_clip
from .data import SampleReference, ctc_frames_needed
from .features import compute_feature_details, compute_features, thin_evenly_frame_indices, trim_frames_without_hands
from .landmarks import (
    CONFIDENCE,
    LEFT_BODY_WRIST,
    LEFT_HAND_START,
    POINTS_PER_FRAME,
    RIGHT_BODY_WRIST,
    RIGHT_HAND_START,
    VALUES_PER_POINT,
    WRIST_JOINT,
    PackedDataset,
)

SENTENCES_TASK_NAME = "sentences"
SENTENCE_MODEL_FRAME_COUNT = 384  # 192 output rows, one per 2 frames
# A word in a real continuous clip's label that isn't in the word list: it can never be read, so it counts as an
# error when measuring and keeps the clip out of training.
UNKNOWN_WORD_NUMBER = -1


@dataclass
class SentenceSettings:
    most_signs: int = 6
    one_sign_share: float = 0.25
    shave_probability: float = 0.5
    largest_shave_fraction: float = 0.2  # up to a fifth off each end
    fewest_frames_after_shaving: int = 4
    fewest_in_between_frames: int = 3
    most_in_between_frames: int = 10
    # The signing part: a wrist above this many body sizes under the centre. A share of clips keep a short rest.
    rest_line_below_centre_in_body_sizes: float = 1.5
    rest_join_share: float = 0.2
    short_rest_frames: int = 8

    def to_dict(self) -> dict:
        return asdict(self)

    def mean_sign_count(self) -> float:
        other_counts = range(2, self.most_signs + 1)
        if not other_counts:
            return 1.0
        return self.one_sign_share + (1 - self.one_sign_share) * float(np.mean(list(other_counts)))


# A real continuous clip's label is its signs in order with this between them ("i|go|school"). A space can't
# be the mark: one sign's own name may hold one ("good morning"), and a spelled phrase is full of them.
SIGN_SEPARATOR_IN_A_LABEL = "|"


def label_words(label: str) -> list[str]:
    return [word.strip() for word in label.split(SIGN_SEPARATOR_IN_A_LABEL) if word.strip()]


def is_continuous_label(label: str) -> bool:
    """A label with `|` in it is a real continuous clip (used as it is), not a single sign."""
    return SIGN_SEPARATOR_IN_A_LABEL in label


def choose_sign_count(generator: np.random.Generator, settings: SentenceSettings) -> int:
    if settings.most_signs <= 1 or generator.random() < settings.one_sign_share:
        return 1
    return int(generator.integers(2, settings.most_signs + 1))


def signing_part(landmarks: np.ndarray, width: float, height: float, settings: SentenceSettings,
                 rest_frames_kept: int = 0) -> np.ndarray:
    """The frames from the first to the last with a wrist above the rest line (plus up to `rest_frames_kept` frames
    either side). The rest line is `rest_line_below_centre_in_body_sizes` body sizes under the frame's centre, both
    as `features.py` measures them; a wrist is the hand's own when the hand counts as seen, else the body pose's on
    that side. A clip with no raised wrist (or nothing measurable) is only trimmed of frames with no hand."""
    trimmed = trim_frames_without_hands(landmarks)
    if trimmed.shape[0] == 0:
        return trimmed
    details = compute_feature_details(trimmed, width, height)
    if details.centre.shape[0] != trimmed.shape[0] or not np.isfinite(details.body_size) or details.body_size <= 0:
        return trimmed
    rest_line_y = details.centre[:, 1] + settings.rest_line_below_centre_in_body_sizes * details.body_size
    raised = np.zeros(trimmed.shape[0], dtype=bool)
    for hand_seen, hand_start, body_wrist in (
        (details.right_hand_seen, RIGHT_HAND_START, RIGHT_BODY_WRIST),
        (details.left_hand_seen, LEFT_HAND_START, LEFT_BODY_WRIST),
    ):
        hand_wrist = trimmed[:, hand_start + WRIST_JOINT]
        pose_wrist = trimmed[:, body_wrist]
        wrist_y = np.where(hand_seen, hand_wrist[:, 1], pose_wrist[:, 1])
        wrist_is_seen = np.where(hand_seen, hand_wrist[:, CONFIDENCE] > 0, pose_wrist[:, CONFIDENCE] > 0)
        raised |= wrist_is_seen & (wrist_y < rest_line_y)
    raised_frames = np.nonzero(raised)[0]
    if raised_frames.size == 0:
        return trimmed
    first = max(int(raised_frames[0]) - rest_frames_kept, 0)
    last = min(int(raised_frames[-1]) + rest_frames_kept, trimmed.shape[0] - 1)
    return trimmed[first : last + 1]


def shave_ends(landmarks: np.ndarray, generator: np.random.Generator, settings: SentenceSettings) -> np.ndarray:
    """Up to a fifth of the frames off each end (each end on its own), never below `fewest_frames_after_shaving`."""
    frame_count = landmarks.shape[0]
    largest_shave = int(frame_count * settings.largest_shave_fraction)
    leading_frames = int(generator.integers(0, largest_shave + 1))
    trailing_frames = int(generator.integers(0, largest_shave + 1))
    if frame_count - leading_frames - trailing_frames < settings.fewest_frames_after_shaving:
        return landmarks
    return landmarks[leading_frames : frame_count - trailing_frames]


@dataclass
class BodyPlacement:
    """Where a clip's body is: its shoulder centre and body size in units where x and y are the same size
    (x × aspect, as in `features.py`), and that aspect. `size_is_measured` is False when the clip has neither
    shoulders nor a measurable hand, so its size is only the fallback 3.5."""

    centre: np.ndarray  # [2]
    body_size: float
    aspect: float
    size_is_measured: bool


def body_placement(landmarks: np.ndarray, width: float, height: float) -> BodyPlacement:
    details = compute_feature_details(landmarks, width, height)
    aspect = float(width) / float(height) if width > 0 and height > 0 else 1.0
    size_is_measured = bool(details.both_shoulders_seen.any() or not details.hand_size_is_degenerate)
    centre = np.median(details.centre, axis=0) if details.centre.shape[0] > 0 else np.array([0.5 * aspect, 0.5])
    return BodyPlacement(centre=centre, body_size=float(details.body_size), aspect=aspect, size_is_measured=size_is_measured)


def move_onto_body(landmarks: np.ndarray, own_placement: BodyPlacement, target_placement: BodyPlacement) -> np.ndarray:
    """Seen points moved and scaled so `own_placement` lands on `target_placement`; the result is in the target's
    picture units (its x is divided by the target's aspect). Unseen points stay (0, 0, 0)."""
    moved = landmarks.astype(np.float32, copy=True)
    point_is_seen = moved[:, :, CONFIDENCE] > 0
    if own_placement.size_is_measured and target_placement.size_is_measured and own_placement.body_size > 0:
        scale_factor = target_placement.body_size / own_placement.body_size
    else:
        scale_factor = 1.0
    own_aspect_scaling = np.array([own_placement.aspect, 1.0])
    target_aspect_scaling = np.array([target_placement.aspect, 1.0])
    places_in_square_units = moved[:, :, :2].astype(np.float64) * own_aspect_scaling
    moved_places = (places_in_square_units - own_placement.centre) * scale_factor + target_placement.centre
    moved[:, :, :2] = np.where(point_is_seen[:, :, None], moved_places / target_aspect_scaling, 0.0)
    return moved


def in_between_frames(last_frame: np.ndarray, next_first_frame: np.ndarray, frame_count: int) -> np.ndarray:
    """`frame_count` frames from one sign's last frame to the next sign's first: points seen in both slide along
    the straight line (smaller confidence), every other point is unseen."""
    joining = np.zeros((frame_count, POINTS_PER_FRAME, VALUES_PER_POINT), dtype=np.float32)
    seen_in_both = (last_frame[:, CONFIDENCE] > 0) & (next_first_frame[:, CONFIDENCE] > 0)
    smaller_confidence = np.minimum(last_frame[:, CONFIDENCE], next_first_frame[:, CONFIDENCE])
    for joining_frame in range(frame_count):
        fraction_of_the_way = (joining_frame + 1) / (frame_count + 1)
        places = last_frame[:, :2] + fraction_of_the_way * (next_first_frame[:, :2] - last_frame[:, :2])
        joining[joining_frame, seen_in_both, :2] = places[seen_in_both]
        joining[joining_frame, seen_in_both, CONFIDENCE] = smaller_confidence[seen_in_both]
    return joining


def join_signs(
    sign_clips: list[tuple[np.ndarray, float, float]],
    generator: np.random.Generator,
    settings: SentenceSettings,
) -> np.ndarray:
    """Steps 2 to 4 for clips given as (landmarks, width, height). Returns the sentence's landmarks in the first
    clip's picture units (its width and height are the sentence's)."""
    joined_parts = []
    first_placement = None
    for sign_number, (landmarks, width, height) in enumerate(sign_clips):
        rest_frames_kept = settings.short_rest_frames if generator.random() < settings.rest_join_share else 0
        sign_landmarks = signing_part(landmarks, width, height, settings, rest_frames_kept)
        if generator.random() < settings.shave_probability:
            sign_landmarks = shave_ends(sign_landmarks, generator, settings)
        if sign_landmarks.shape[0] == 0:
            continue
        own_placement = body_placement(sign_landmarks, width, height)
        if first_placement is None:
            first_placement = own_placement
        sign_landmarks = move_onto_body(sign_landmarks, own_placement, first_placement)
        if joined_parts:
            joining_frame_count = int(
                generator.integers(settings.fewest_in_between_frames, settings.most_in_between_frames + 1)
            )
            joined_parts.append(in_between_frames(joined_parts[-1][-1], sign_landmarks[0], joining_frame_count))
        joined_parts.append(sign_landmarks)
    if not joined_parts:
        return np.zeros((0, POINTS_PER_FRAME, VALUES_PER_POINT), dtype=np.float32)
    return np.concatenate(joined_parts).astype(np.float32)


# ---- choosing the clips -----------------------------------------------------------------------------------------


@dataclass
class SentenceItem:
    """One sample: either a built sentence (several single-sign clips) or one real continuous clip."""

    references: list[SampleReference]
    word_numbers: list[int]  # word i of the list is i; UNKNOWN_WORD_NUMBER for a word the model doesn't have
    is_real_continuous_clip: bool

    @property
    def sign_count(self) -> int:
        return len(self.word_numbers)


class SentencePlanner:
    """Chooses clips for built sentences from one split's single-sign clips whose word is in the word list."""

    def __init__(self, sources: list[PackedDataset], sample_references: list[SampleReference], word_list: list[str]):
        word_number_by_word = {word: word_number for word_number, word in enumerate(word_list)}
        self.word_number_by_word = word_number_by_word
        self.single_sign_references = [
            reference
            for reference in sample_references
            if not is_continuous_label(reference.label) and reference.label.strip() in word_number_by_word
        ]
        # Same signer means the same person in the same dataset: "1" in one dataset is not "1" in another.
        self.references_by_signer: dict[tuple[int, str], list[SampleReference]] = {}
        for reference in self.single_sign_references:
            if reference.signer.strip():
                self.references_by_signer.setdefault((reference.source_number, reference.signer), []).append(reference)

    def word_number(self, word: str) -> int:
        return self.word_number_by_word.get(word, UNKNOWN_WORD_NUMBER)

    def plan_sentence(self, generator: np.random.Generator, settings: SentenceSettings) -> SentenceItem:
        sign_count = choose_sign_count(generator, settings)
        first_reference = self.single_sign_references[int(generator.integers(len(self.single_sign_references)))]
        if first_reference.signer.strip():
            candidates = self.references_by_signer[(first_reference.source_number, first_reference.signer)]
        else:
            candidates = self.single_sign_references
        chosen_references = [first_reference] + [
            candidates[int(generator.integers(len(candidates)))] for sign_number in range(sign_count - 1)
        ]
        return SentenceItem(
            references=chosen_references,
            word_numbers=[self.word_number(reference.label.strip()) for reference in chosen_references],
            is_real_continuous_clip=False,
        )

    def plan_sentences(self, sentence_count: int, generator: np.random.Generator, settings: SentenceSettings) -> list[SentenceItem]:
        if not self.single_sign_references:
            return []
        return [self.plan_sentence(generator, settings) for sentence_number in range(sentence_count)]


def real_continuous_items(
    sample_references: list[SampleReference], word_list: list[str], keep_clips_with_unknown_words: bool
) -> list[SentenceItem]:
    """Manifest rows whose label is several signs joined with `|`, as they are. In training a clip with a word not in the list
    is left out (it can't be learned); in measuring it is kept, and the unknown word counts as an error."""
    word_number_by_word = {word: word_number for word_number, word in enumerate(word_list)}
    items = []
    for reference in sample_references:
        if not is_continuous_label(reference.label):
            continue
        word_numbers = [word_number_by_word.get(word, UNKNOWN_WORD_NUMBER) for word in label_words(reference.label)]
        if UNKNOWN_WORD_NUMBER in word_numbers and not keep_clips_with_unknown_words:
            continue
        items.append(SentenceItem(references=[reference], word_numbers=word_numbers, is_real_continuous_clip=True))
    return items


# ---- the torch Dataset -----------------------------------------------------------------------------------------


class SentenceDataset(Dataset):
    """Returns (features [T ≤ 384, 117], mask [T], CTC targets [L]) like the finger-spelling dataset, so the
    finger-spelling collate, loss and decoding work unchanged. Target i + 1 is word i (0 is the CTC blank); a word
    the model doesn't have is left out of the target (it only counts when measuring).

    Training (`fresh_sentence_count` > 0): `set_epoch` plans that many new sentences from the training clips,
    seeded by (seed, epoch), plus every real continuous training clip; samples are augmented. Measuring: the
    sentences are planned once from `seed` in `__init__` and never change, so every epoch and every later
    evaluation reads the same sentences."""

    def __init__(
        self,
        sources: list[PackedDataset],
        sample_references: list[SampleReference],
        word_list: list[str],
        sentence_settings: SentenceSettings,
        augment_settings: AugmentSettings | None,
        seed: int,
        fresh_sentence_count: int = 0,
        fixed_sentence_count: int = 0,
        frame_count: int = SENTENCE_MODEL_FRAME_COUNT,
    ):
        self.sources = sources
        self.word_list = word_list
        self.sentence_settings = sentence_settings
        self.augment_settings = augment_settings
        self.seed = seed
        self.frame_count = frame_count
        self.fresh_sentence_count = fresh_sentence_count
        self.planner = SentencePlanner(sources, sample_references, word_list)
        is_training = fresh_sentence_count > 0
        self.real_items = real_continuous_items(sample_references, word_list, keep_clips_with_unknown_words=not is_training)
        if is_training:
            # A real clip too long for the model's rows can't be learned by CTC; it is left out of training.
            output_row_count = frame_count // 2
            self.real_items = [
                item for item in self.real_items if ctc_frames_needed(item.word_numbers) <= output_row_count
            ]
        self.epoch = 0
        if is_training:
            self.set_epoch(0)
        else:
            fixed_sentences = self.planner.plan_sentences(
                fixed_sentence_count, np.random.default_rng([seed, 0]), sentence_settings
            )
            self.items = fixed_sentences + self.real_items

    def set_epoch(self, epoch: int) -> None:
        self.epoch = epoch
        if self.fresh_sentence_count > 0:
            fresh_sentences = self.planner.plan_sentences(
                self.fresh_sentence_count, np.random.default_rng([self.seed, epoch, 0]), self.sentence_settings
            )
            self.items = fresh_sentences + self.real_items

    def __len__(self) -> int:
        return len(self.items)

    def item_landmarks(self, item_number: int, generator: np.random.Generator) -> tuple[np.ndarray, float, float]:
        """The item's landmarks (joined for a built sentence, trimmed for a real clip) and its picture size."""
        item = self.items[item_number]
        sign_clips = []
        for reference in item.references:
            source = self.sources[reference.source_number]
            clip_record = source.clip_records[reference.clip_number]
            sign_clips.append((source.clip(reference.clip_number), clip_record.width, clip_record.height))
        first_width, first_height = sign_clips[0][1], sign_clips[0][2]
        if item.is_real_continuous_clip:
            return trim_frames_without_hands(sign_clips[0][0]), first_width, first_height
        return join_signs(sign_clips, generator, self.sentence_settings), first_width, first_height

    def __getitem__(self, item_number: int):
        if self.fresh_sentence_count > 0:
            generator = np.random.default_rng([self.seed, self.epoch, 1, item_number])
        else:
            generator = np.random.default_rng([self.seed, 1, item_number])
        landmarks, width, height = self.item_landmarks(item_number, generator)
        if self.augment_settings is not None and landmarks.shape[0] > 0:
            picture_aspect = width / height if width > 0 and height > 0 else 1.0
            landmarks = augment_clip(landmarks, generator, self.augment_settings, picture_aspect)
        features = compute_features(landmarks, width, height)
        features = features[thin_evenly_frame_indices(features.shape[0], self.frame_count)]
        target_numbers = [word_number + 1 for word_number in self.items[item_number].word_numbers if word_number >= 0]
        return (
            torch.from_numpy(np.ascontiguousarray(features)),
            torch.ones(features.shape[0]),
            torch.tensor(target_numbers, dtype=torch.int64),
        )
