# About LLMs in this project

This page is here for transparency. NebulaAPI was built with help from large language
models, and I'd rather say exactly how than leave you guessing. The short version: the
architecture is human, the LLMs are tools held on a short leash, and nothing ships without
me reviewing it.

## Provenance — the idea is human

I designed NebulaAPI and wrote its first version myself, without any LLM. The project was
first committed on **27 March 2024** (`feat: scaffold project + initial defapi macro`). The
core concept — declare a cluster topology of nodes and tags, let the *compiler* decide what
runs where, and emit either a real implementation or a transparent RPC stub per node — is
mine. It came out of running [podCloud](https://podcloud.fr) on a real cluster and wanting
the flexibility of umbrella releases without rewriting code every time the topology moved.

That idea, and the mental model the whole library is organized around, did not come from a
model. It came from the problem.

## The LLM-assisted phase — hardening and reach

From late 2025 I started using LLMs to *strengthen* and *extend* the working library, always
against an architecture I had already decided. Multicast and unicast call routing landed on
**21 December 2025** (`feat(nebula-api): add multicast and unicast call support`); most of
the resilience work — confined calls, the per-worker queue, the boot-time node policy, the
configured-set quorum — was done in this phase too.

In every case the *what* and the *why* were mine. The model worked on the *how*, and only
after I'd said where we were going.

## What the LLMs actually do here

Their role is deliberately bounded:

- **Code generation from a human design.** I describe the behavior, the constraints, and the
  shape I want; the model writes Elixir against that. I read it.
- **Automated, adversarial review.** I use models as a tireless reviewer — to read the diff
  cold, treat every doc example as an assertion to execute, and surface substantive problems
  (correctness bugs, doc-vs-code drift, missing edge cases). This catches real issues I'd
  miss on a solo project. The reviews *raise* problems; they don't get to decide what's done
  about them.
- **Documentation drafting.** Including this page — written by a model, to my instructions,
  and edited by me.

## What they do not do

- They **do not** make architectural decisions. Tradeoffs, the data model, the public API,
  the breaking changes — those are mine.
- They **do not** get the final word on whether something is correct. A model's confidence is
  not evidence; claims get verified (the test suite runs as a distributed node, and findings
  are reproduced empirically before they count).
- They **do not** merge. **No version reaches `main` without my review and explicit
  validation.** Every merge is a human decision, `--no-ff`, after I've read the work — the
  git history reflects that.

## The stance, in one line

LLMs made this library better and faster to harden than I could have alone. They did not
design it, they do not run unsupervised, and they do not get to ship. A human is responsible
for every line that ends up in a release — that human is me.

— Pof (Giovanni Olivera)
