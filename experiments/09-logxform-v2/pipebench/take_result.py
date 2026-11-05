#!/usr/bin/env python3
"""Keeps one test's result from PipeBench's per-subject file. usage: take_result.py SUBJECT_JSON TEST OUT_JSON LOAD_BEFORE"""
import json, sys
src, test, out, load = sys.argv[1:5]
rows = [r for r in json.load(open(src))["results"] if r["test"] == test]
if not rows:
    print("no result for", test); sys.exit(1)
r = rows[-1]; r["load_before"] = load
json.dump(r, open(out, "w"), indent=1)
