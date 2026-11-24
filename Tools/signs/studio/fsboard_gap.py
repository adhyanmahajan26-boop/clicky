"""Apple Vision vs FSboard's own MediaPipe landmarks on the same clips.
usage (from Tools/signs, venv python): fsboard_gap.py <shard> <metadata.json> <apple landmarks folder> <chosen.json>
FSboard's shards are scrambled (signs/fsboard_source.py): only hand joints 0-6 survive whole, so the joint comparison
uses the 7 whole joints (0-6: wrist, thumb, index knuckle and middle joint), (joint - wrist) / Apple's hand size, the features' own normalising."""
import json, sys
import numpy as np
from pathlib import Path
from signs.fsboard_source import read_shard_rows, parse_sequence_example, clip_key_from_video_name, load_metadata, clip_file_stem, unscramble_landmarks
from signs.landmarks import read_clip, RIGHT_HAND_START, LEFT_HAND_START, CONFIDENCE
from signs.features import compute_features  # noqa: F401  (imported to be sure the module loads)

shard, metadata_path, apple_folder, chosen_path = sys.argv[1:5]
meta = load_metadata(metadata_path)
chosen = {clip_file_stem(r) for r in json.loads(Path(chosen_path).read_text())}
totals = dict(clips=0, frames_compared=0, mp_hand=0, apple_hand=0, both_hand=0, mp_right=0, mp_left=0, apple_right=0, apple_left=0,
              same_side=0, side_pairs=0, frame_count_mismatch=0)
normalised_gaps = []
picture_gaps = []
for ser in read_shard_rows(shard):
    ctx, fl = parse_sequence_example(ser)
    rec = meta.get(clip_key_from_video_name(ctx['video_name']))
    if rec is None or clip_file_stem(rec) not in chosen:
        continue
    apple_path = Path(apple_folder) / f"fsboard-apple-{clip_file_stem(rec)}.npy"
    if not apple_path.exists():
        continue
    apple_full = read_clip(apple_path)
    # The video clip starts before the signed part MediaPipe's frames cover (clipStartTimeS < annotationStartTimeS),
    # so Apple's frame i + offset is MediaPipe's frame i. The offset comes from the metadata's times.
    offset = max(0, round((rec['annotationStartTimeS'] - rec['clipStartTimeS']) * ctx['image/frame_rate']))
    apple = apple_full[offset:]
    totals['offset_frames_total'] = totals.get('offset_frames_total', 0) + offset
    frame_count = min(len(apple), ctx['num_frames'])
    totals['clips'] += 1
    totals['frame_count_mismatch'] += int(abs(len(apple) - ctx['num_frames']) > 2)
    aspect = ctx['image/width'] / ctx['image/height']
    # Apple's hand size for this clip: 90th percentile of wrist -> middle knuckle over frames the hand is seen
    sizes = []
    for start in (RIGHT_HAND_START, LEFT_HAND_START):
        seen = (apple[:, start, CONFIDENCE] > 0) & (apple[:, start + 9, CONFIDENCE] > 0)
        delta = apple[seen, start + 9, :2] - apple[seen, start, :2]
        delta[:, 0] *= aspect
        sizes += list(np.hypot(delta[:, 0], delta[:, 1]))
    hand_size = np.percentile(sizes, 90) if sizes else None
    for frame in range(frame_count):
        mp_hands = {}
        for part in ('right_hand', 'left_hand'):
            x, y, z = fl['x_' + part][frame], fl['y_' + part][frame], fl['z_' + part][frame]
            if len(x) >= 3:
                mp_hands[part] = unscramble_landmarks(x, y, z)[:8, :2]
        apple_hands = {}
        for side, start in (('right', RIGHT_HAND_START), ('left', LEFT_HAND_START)):
            if apple[frame, start, CONFIDENCE] > 0:
                apple_hands[side] = apple[frame, start:start + 21]
        totals['frames_compared'] += 1
        totals['mp_hand'] += int(bool(mp_hands)); totals['apple_hand'] += int(bool(apple_hands))
        totals['both_hand'] += int(bool(mp_hands) and bool(apple_hands))
        totals['mp_right'] += int('right_hand' in mp_hands); totals['mp_left'] += int('left_hand' in mp_hands)
        totals['apple_right'] += int('right' in apple_hands); totals['apple_left'] += int('left' in apple_hands)
        # pair each MediaPipe hand with the Apple hand whose wrist is nearest
        for part, mp in mp_hands.items():
            if not apple_hands:
                continue
            side, ap = min(apple_hands.items(), key=lambda item: np.hypot(*(item[1][0, :2] - mp[0])))
            totals['side_pairs'] += 1
            totals['same_side'] += int(part.startswith(side))
            seen = ap[:len(mp), CONFIDENCE] > 0
            if not seen[0]:
                continue
            for joint in np.nonzero(seen)[0]:
                gap = (ap[joint, :2] - mp[joint]).astype(float)
                gap[0] *= aspect
                picture_gaps.append(np.hypot(*gap))
                if joint > 0 and hand_size:
                    apple_relative = (ap[joint, :2] - ap[0, :2]).astype(float); mp_relative = (mp[joint] - mp[0]).astype(float)
                    apple_relative[0] *= aspect; mp_relative[0] *= aspect
                    normalised_gaps.append(np.hypot(*(apple_relative - mp_relative)) / hand_size)
f = totals['frames_compared']
print(json.dumps(totals))
print(f"frames with a hand: MediaPipe {totals['mp_hand']/f:.1%}, Apple {totals['apple_hand']/f:.1%}, both {totals['both_hand']/f:.1%}")
print(f"MediaPipe right_hand {totals['mp_right']/f:.1%} left_hand {totals['mp_left']/f:.1%}; Apple signer-right {totals['apple_right']/f:.1%} signer-left {totals['apple_left']/f:.1%}")
print(f"paired hands: MediaPipe's part name matches Apple's signer side in {totals['same_side']/max(totals['side_pairs'],1):.1%} of {totals['side_pairs']}")
pg = np.array(picture_gaps); ng = np.array(normalised_gaps)
print(f"joints 0-6, distance in picture heights: median {np.median(pg):.4f}, mean {pg.mean():.4f}, 90th {np.percentile(pg, 90):.4f} ({len(pg)} joints)")
print(f"joints 1-6 relative to the wrist, in hand sizes (the features' normalising): median {np.median(ng):.3f}, mean {ng.mean():.3f}, 90th {np.percentile(ng, 90):.3f} ({len(ng)} joints)")
