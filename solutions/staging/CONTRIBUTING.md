- [1. Basic Information](#1-basic-information)
  - [1.1. What does this code do?](#11-what-does-this-code-do)
  - [1.2. Who might work in this repository?](#12-who-might-work-in-this-repository)
  - [1.3. Where do builds live?](#13-where-do-builds-live)
  - [1.4. How do releases work?](#14-how-do-releases-work)
- [2. Making Changes](#2-making-changes)
  - [2.1. General Contribution Guidance](#21-general-contribution-guidance)
  - [2.2. Where do I make changes?](#22-where-do-i-make-changes)
  - [2.3. Review Process](#23-review-process)
- [3. Building](#3-building)
- [4. Testing](#4-testing)
- [5. Repository Structure](#5-repository-structure)
- [6. CICD Pipeline](#6-cicd-pipeline)
  - [6.1. Understanding the build process](#61-understanding-the-build-process)
  - [6.2. Understanding Artifacts](#62-understanding-artifacts)
  - [6.3. Understanding how the pipeline works](#63-understanding-how-the-pipeline-works)
  - [6.4. Understanding the production promotion process](#64-understanding-the-production-promotion-process)
  - [6.5. Summarized end to end flow](#65-summarized-end-to-end-flow)

# 1. Basic Information
## 1.1. What does this code do?

...

## 1.2. Who might work in this repository?

...

## 1.3. Where do builds live?

...

## 1.4. How do releases work?

...

# 2. Making Changes
## 2.1. General Contribution Guidance

Always create a new branch from ValidatedDesigns\master.
  - This repository uses [GitHub branch protection](https://help.github.com/en/github/administering-a-repository/about-protected-branches)
  - The purpose of creating a new branch is to develop pipeline/build changes or add new solutions, the goal of doing a GitHub pull request back into master branch.

Make as few changes as technically required.
  - Keeping PRs small and hermetic makes changes easier to review and lessens the potential regression blast radius.

Keep good documentation (be kind to your future self and fellow developers!)
  - Contribute to the README, CONTRIBUTING, and other documentation. Follow airport security rules: If you see something, say something.
  - Keep good a good CHANGELOG. It is a pain to dig through mountains of PRs to try to figure out why something was done.

Build locally before creating a PR.
  - Building locally ensures that you have confidence in your change before asking others to review it.
  - See "How do I build locally?" section for details.

Do functional testing before final PR merges.
  - See "Testing" section for details.

Document and/or address technical debt.
  - Contributions, even small, for cleanups and debt reduction are always welcome; however, we know that free time is always in short supply.
  - At minimum, if you see something that should be TODO'd in the future, please add in-line TODO comments where applicable.
  - For those just getting started, addressing even a small TODO item is a great way to learn and see the process in action.

## 2.2. Where do I make changes?

...

## 2.3. Review Process

...

# 3. Building

...

# 4. Testing

...

# 5. Repository Structure

```
... Insert Tree here
```

# 6. CICD Pipeline

## 6.1. Understanding the build process

...

## 6.2. Understanding Artifacts

...

## 6.3. Understanding how the pipeline works

...

## 6.4. Understanding the production promotion process

...

## 6.5. Summarized end to end flow

...