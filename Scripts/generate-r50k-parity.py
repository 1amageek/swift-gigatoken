#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import tiktoken
from tiktoken.load import load_tiktoken_bpe


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/GigaTokenTests/Fixtures"
MODEL = FIXTURES / "r50k_base.tiktoken"
CORPUS = FIXTURES / "r50k_parity.json"
PATTERN = r"'(?:s|t|re|ve|m|ll|d)| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    arguments = parser.parse_args()
    fixtures = json.loads(CORPUS.read_text())
    encoding = tiktoken.Encoding(
        name="swift-gigatoken-r50k-parity",
        pat_str=PATTERN,
        mergeable_ranks=load_tiktoken_bpe(str(MODEL)),
        special_tokens={"<|endoftext|>": 50256},
    )
    generated = [
        {"text": fixture["text"], "tokens": encoding.encode_ordinary(fixture["text"])}
        for fixture in fixtures
    ]
    if arguments.write:
        CORPUS.write_text(json.dumps(generated, ensure_ascii=False, separators=(",", ":")))
        print(f"r50k-parity: wrote {CORPUS}")
        return
    if generated != fixtures:
        raise SystemExit(f"Parity fixture is stale: {CORPUS}")
    print(f"r50k-parity: verified {len(fixtures)} fixtures")


if __name__ == "__main__":
    main()
