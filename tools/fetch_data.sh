#!/bin/zsh
# Downloads the raw word frequency lists into data-raw/ (not kept in git).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data-raw && cd data-raw
FW=https://raw.githubusercontent.com/hermitdave/FrequencyWords/master
for l in ru en sk; do curl -sSfL -o ${l}_full.txt $FW/content/2018/$l/${l}_full.txt; done
curl -sSfL -o FW_LICENSE $FW/LICENSE
WWF=https://raw.githubusercontent.com/IlyaSemenov/wikipedia-word-frequency/master
curl -sSfL -o enwiki.txt $WWF/results/enwiki-2023-04-13.txt
curl -sSfL -o ruwiki.txt $WWF/results/ruwiki-2022-08-29.txt
curl -sSfL -o WWF_LICENSE $WWF/LICENSE
