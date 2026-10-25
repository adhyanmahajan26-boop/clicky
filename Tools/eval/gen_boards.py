#!/usr/bin/env python3
"""Whiteboard generation eval for Clicky (P4): does the model write boards
our parser reads without the Haiku repair call?

Asks the `claude` CLI directly (never the app) 25 concept prompts x 2 runs,
with the WHITEBOARD prompt section as the whole system prompt and
"MODE: whiteboard" on the user message, isolated like the app's calls (no
tools, no MCP, no hooks, user settings only, no saved session, no CLAUDE.md,
cwd $TMPDIR/clicky-session). Answers go to build/eval/gen_boards/<n>.txt;
existing ones are skipped, so a run stopped by usage limits resumes where it
left off. Then each answer is checked with cwb-check (scanner -> repair ->
normalizer) and the parse rate and repair-rung histogram are printed.

The system prompt is read from
Packages/ClickyCore/Sources/ClickyCore/Whiteboard/WhiteboardPromptSection.swift
so the eval always sends the text the app registers.

Usage: python3 -I Tools/eval/gen_boards.py [--runs 2] [--only 1,2,3] [--check-only]
"""

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import tempfile
import time

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
PACKAGE_PATH = os.path.join(REPO_ROOT, "Packages", "ClickyCore")
PROMPT_SWIFT_PATH = os.path.join(PACKAGE_PATH, "Sources", "ClickyCore", "Whiteboard", "WhiteboardPromptSection.swift")
OUTPUT_DIRECTORY = os.path.join(REPO_ROOT, "build", "eval", "gen_boards")

BATCH_SIZE = 10
FIRST_BACKOFF_SECONDS = 30
LAST_BACKOFF_SECONDS = 8 * 60
CALL_TIMEOUT_SECONDS = 600

CONCEPT_PROMPTS = [
    "how does https work?",
    "explain the tcp three-way handshake",
    "how does git branching and merging work?",
    "how does react decide what to re-render?",
    "explain compound interest with an example",
    "how does photosynthesis work?",
    "what happens when i type a url into the browser and press enter?",
    "how does dns resolution work?",
    "explain big o notation, and how is binary search o of log n?",
    "how does a hash map work under the hood?",
    "explain how public key cryptography works",
    "how do vaccines train the immune system?",
    "what's the difference between a process and a thread? and when would i use each?",
    "how does garbage collection work in java?",
    "explain supply and demand",
    "how does a neural network learn with backpropagation?",
    "explain the water cycle",
    "how does oauth login with google work?",
    "explain recursion using the fibonacci sequence",
    "how does a car engine work?",
    "what is the pythagorean theorem and why is it true?",
    "how do database indexes make queries faster?",
    "explain how the electoral college works",
    "how does the heart pump blood around the body?",
    "what is a closure in javascript? and how is it different from a class?",
]

USAGE_LIMIT_PATTERN = re.compile(r"usage limit|rate limit|limit reached|too many requests|\b429\b|overloaded|try again later", re.IGNORECASE)


def read_prompt_section():
    """The text of WhiteboardPromptSection.text (a raw multi-line literal)."""
    with open(PROMPT_SWIFT_PATH, encoding="utf-8") as swift_file:
        swift_source = swift_file.read()
    match = re.search(r'#"""\n(.*?)\n( *)"""#', swift_source, re.DOTALL)
    if not match:
        sys.exit("can't find the prompt literal in " + PROMPT_SWIFT_PATH)
    indentation = match.group(2)
    lines = match.group(1).split("\n")
    return "\n".join(line[len(indentation):] if line.startswith(indentation) else line.lstrip() for line in lines) + "\n"


def session_working_directory():
    working_directory = os.path.join(tempfile.gettempdir(), "clicky-session")
    os.makedirs(working_directory, exist_ok=True)
    return working_directory


def call_claude(prompt_text, system_prompt_path):
    """One CLI call; returns (answer_text or None, error_text or None)."""
    command = [
        "claude", "-p", "MODE: whiteboard\n" + prompt_text,
        "--output-format", "json",
        "--tools", "",
        "--model", "sonnet",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--setting-sources", "user",
        "--settings", '{"disableAllHooks":true}',
        "--system-prompt-file", system_prompt_path,
    ]
    environment = dict(os.environ)
    environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
    try:
        completed = subprocess.run(command, cwd=session_working_directory(), env=environment,
                                   stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                   timeout=CALL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    output_text = completed.stdout.strip()
    try:
        result_object = json.loads(output_text)
    except ValueError:
        return None, (output_text or completed.stderr.strip() or "exit %d" % completed.returncode)[:500]
    if result_object.get("is_error") or result_object.get("subtype") != "success":
        return None, str(result_object.get("result") or result_object.get("subtype") or "error")[:500]
    return result_object.get("result") or "", None


def generate_one(job_number, prompt_text, system_prompt_path):
    """Calls with exponential backoff on usage-limit errors; saves <n>.txt."""
    answer_path = os.path.join(OUTPUT_DIRECTORY, "%d.txt" % job_number)
    backoff_seconds = FIRST_BACKOFF_SECONDS
    while True:
        answer_text, error_text = call_claude(prompt_text, system_prompt_path)
        if answer_text is not None:
            temporary_path = answer_path + ".part"
            with open(temporary_path, "w", encoding="utf-8") as answer_file:
                answer_file.write(answer_text)
            os.replace(temporary_path, answer_path)
            return job_number, None
        is_usage_limit = bool(USAGE_LIMIT_PATTERN.search(error_text or ""))
        if not is_usage_limit or backoff_seconds > LAST_BACKOFF_SECONDS:
            return job_number, error_text
        print("  #%d: %s; retrying in %ds" % (job_number, error_text[:80], backoff_seconds), flush=True)
        time.sleep(backoff_seconds)
        backoff_seconds *= 2


def generate(jobs, system_prompt_path):
    pending_jobs = [(number, prompt) for number, prompt in jobs
                    if not os.path.exists(os.path.join(OUTPUT_DIRECTORY, "%d.txt" % number))]
    print("generating %d of %d answers (%d already saved)" % (len(pending_jobs), len(jobs), len(jobs) - len(pending_jobs)), flush=True)
    failures = {}
    for batch_start in range(0, len(pending_jobs), BATCH_SIZE):
        batch = pending_jobs[batch_start:batch_start + BATCH_SIZE]
        print("batch %d: #%s" % (batch_start // BATCH_SIZE + 1, ",".join(str(number) for number, _ in batch)), flush=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=BATCH_SIZE) as executor:
            futures = [executor.submit(generate_one, number, prompt, system_prompt_path) for number, prompt in batch]
            for future in concurrent.futures.as_completed(futures):
                job_number, error_text = future.result()
                if error_text:
                    failures[job_number] = error_text
                    print("  #%d failed: %s" % (job_number, error_text[:120]), flush=True)
        if any(USAGE_LIMIT_PATTERN.search(error) for error in failures.values()):
            print("stopping: usage limit still hit after backoff; rerun to resume", flush=True)
            break
    return failures


def cwb_check_binary():
    subprocess.run(["swift", "build", "--package-path", PACKAGE_PATH, "--product", "cwb-check"], check=True,
                   stdout=subprocess.DEVNULL)
    bin_directory = subprocess.run(["swift", "build", "--package-path", PACKAGE_PATH, "--show-bin-path"],
                                   check=True, capture_output=True, text=True).stdout.strip()
    return os.path.join(bin_directory, "cwb-check")


def check(jobs):
    binary_path = cwb_check_binary()
    rung_totals = {}
    parsed_count = 0
    checked_count = 0
    failed_jobs = []
    for job_number, prompt_text in jobs:
        answer_path = os.path.join(OUTPUT_DIRECTORY, "%d.txt" % job_number)
        if not os.path.exists(answer_path):
            continue
        checked_count += 1
        completed = subprocess.run([binary_path, answer_path], capture_output=True, text=True)
        try:
            check_result = json.loads(completed.stdout.strip())
        except ValueError:
            failed_jobs.append((job_number, "cwb-check output: " + completed.stdout[:100] + completed.stderr[:100]))
            continue
        for rung_name, rung_count in check_result["rungs"].items():
            rung_totals[rung_name] = rung_totals.get(rung_name, 0) + rung_count
        if check_result["ok"]:
            parsed_count += 1
        else:
            with open(answer_path, encoding="utf-8") as answer_file:
                has_block = "<whiteboard>" in answer_file.read().lower()
            failed_jobs.append((job_number, "%s (%s)" % (json.dumps(check_result), "block" if has_block else "no block")))
    print()
    print("parse rate without repair-by-Haiku: %d/%d%s" % (
        parsed_count, checked_count,
        " (%.1f%%)" % (100.0 * parsed_count / checked_count) if checked_count else ""))
    print("rungs: " + json.dumps(rung_totals))
    for job_number, reason in failed_jobs:
        print("  not ok #%d: %s" % (job_number, reason))
    return parsed_count, checked_count


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--only", default="", help="comma-separated job numbers")
    parser.add_argument("--check-only", action="store_true")
    arguments = parser.parse_args()

    jobs = []
    for run_index in range(arguments.runs):
        for prompt_index, prompt_text in enumerate(CONCEPT_PROMPTS):
            jobs.append((run_index * len(CONCEPT_PROMPTS) + prompt_index + 1, prompt_text))
    if arguments.only:
        wanted_numbers = {int(number) for number in arguments.only.split(",")}
        jobs = [job for job in jobs if job[0] in wanted_numbers]

    os.makedirs(OUTPUT_DIRECTORY, exist_ok=True)
    if not arguments.check_only:
        system_prompt_path = os.path.join(OUTPUT_DIRECTORY, "whiteboard_system_prompt.txt")
        with open(system_prompt_path, "w", encoding="utf-8") as prompt_file:
            prompt_file.write(read_prompt_section())
        os.chmod(system_prompt_path, 0o600)
        failures = generate(jobs, system_prompt_path)
        if failures:
            print("%d calls failed: %s" % (len(failures), ", ".join("#%d" % number for number in sorted(failures))))
    check(jobs)


if __name__ == "__main__":
    main()
