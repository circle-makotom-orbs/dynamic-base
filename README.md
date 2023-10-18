# dynamic-base

## Example usage

Prerequisite: Configure `GITHUB_API_TOKEN` project environment variable with a GitHub PAT that can access PRs of interest first.

```
version: 2.1

orbs:
  dynamic-base: circle-makotom-orbs/dynamic-base@volatile

parameters:
  is-continuation:
    type: boolean
    default: false
  run-x:
    type: boolean
    default: false
  run-y:
    type: boolean
    default: false
  run-all:
    type: boolean
    default: false

setup: << ! pipeline.parameters.is-continuation >>

jobs:
  build:
    docker:
      - image: alpine
    steps:
      - run: echo Build

  test:
    docker:
      - image: alpine
    steps:
      - when:
          condition:
            or:
              - << pipeline.parameters.run-x >>
              - << pipeline.parameters.run-all >>
          steps:
            - run: echo Test X
      - when:
          condition:
            or:
              - << pipeline.parameters.run-y >>
              - << pipeline.parameters.run-all >>
          steps:
            - run: echo Test Y

  deploy:
    docker:
      - image: alpine
    steps:
      - run: echo Deploy

workflows:
  # This is where dynamic determination of the base branch and parameter values happens
  setup:
    when:
      not: << pipeline.parameters.is-continuation >>
    jobs:
      - dynamic-base/determine-base-and-continue-with-params:
          continue-config-path: .circleci/config.yml

          # For parameter condition statements, each row should follow this format:
          # grep-pattern "\t" name-of-param-to-assert
          # .* -> is-continuation is a convenient gimmick to reuse the same config for both setup and continuation, by dynamically flipping the `setup` key
          parameter-conditions: |
            .*	is-continuation
            dir-a/.*	run-x
            dir-b/.*	run-y
            .circleci/config.yml	run-all

          default-branch: main
          force-all: false

  build-test-deploy:
    when: << pipeline.parameters.is-continuation >>
    jobs:
      - build
      - test:
          requires:
            - build
      - deploy:
          requires:
            - test
```
