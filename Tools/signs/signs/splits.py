"""Signer-independent splits (SPEC section 5): every reported number is on signers the model never saw."""

from __future__ import annotations

import numpy as np

TRAIN_SPLIT = "train"
VALIDATION_SPLIT = "val"
TEST_SPLIT = "test"
SPLIT_NAMES = (TRAIN_SPLIT, VALIDATION_SPLIT, TEST_SPLIT)


def split_signers(
    signers, seed: int, test_fraction: float = 0.15, validation_fraction: float = 0.1
) -> dict[str, str]:
    """Assigns each distinct signer to "train", "val" or "test".

    Deterministic for a given set of signers and seed, whatever order they come in: the distinct signers are
    sorted as text, shuffled with `numpy.random.default_rng(seed)`, and the first round(n × test_fraction) go to
    test, the next round(n × validation_fraction) to validation, the rest to train. With 3 or more signers, test
    and validation each get at least one when their fraction is above 0. The fractions are of signers, not of clips.
    """
    distinct_signers = sorted({str(signer) for signer in signers})
    signer_count = len(distinct_signers)
    shuffled_order = np.random.default_rng(seed).permutation(signer_count)
    shuffled_signers = [distinct_signers[position] for position in shuffled_order]

    test_signer_count = int(round(signer_count * test_fraction))
    validation_signer_count = int(round(signer_count * validation_fraction))
    # A small dataset still gets one test and one validation signer when it asks for any at all.
    if signer_count >= 3 and test_fraction > 0:
        test_signer_count = max(test_signer_count, 1)
    if signer_count >= 3 and validation_fraction > 0:
        validation_signer_count = max(validation_signer_count, 1)
    # Always leave at least one signer to train on.
    test_signer_count = min(test_signer_count, max(signer_count - 1, 0))
    validation_signer_count = min(validation_signer_count, max(signer_count - 1 - test_signer_count, 0))

    split_by_signer = {}
    for position, signer in enumerate(shuffled_signers):
        if position < test_signer_count:
            split_by_signer[signer] = TEST_SPLIT
        elif position < test_signer_count + validation_signer_count:
            split_by_signer[signer] = VALIDATION_SPLIT
        else:
            split_by_signer[signer] = TRAIN_SPLIT
    return split_by_signer
