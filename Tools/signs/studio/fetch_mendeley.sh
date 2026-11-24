#!/bin/zsh
# The Mendeley files for round 6, each over 16 parallel range requests (one connection gets well under 1 MB/s).
cd ~/sign-data/downloads
F=~/sign-data/tools/fetch.py
/usr/bin/python3 $F https://data.mendeley.com/public-files/datasets/2tj6c7pzfk/files/6b88e649-3fae-41e1-b0eb-b78788a00f03/file_downloaded isl-alphabet-multimodal/Dataset.zip --connections 16
/usr/bin/python3 $F https://data.mendeley.com/public-files/datasets/rc349j45m5/files/db0df065-3190-45ed-9f1f-53bf257a41f8/file_downloaded islan/Alphabets.zip --connections 16
/usr/bin/python3 $F https://data.mendeley.com/public-files/datasets/rc349j45m5/files/5bba025c-6e16-4287-b6eb-4db066b17c31/file_downloaded islan/Multi-Signers.zip --connections 16
mv isl-csltr/ISL_CSLRT_Corpus.zip isl-csltr/ISL_CSLRT_Corpus.zip.single 2>/dev/null; rm -f isl-csltr/ISL_CSLRT_Corpus.zip.single
/usr/bin/python3 $F https://data.mendeley.com/public-files/datasets/kcmpdxky7p/files/c14c8953-be53-4c7a-85d5-5bcd7e79d86e/file_downloaded isl-csltr/ISL_CSLRT_Corpus.zip --connections 24
echo all done
