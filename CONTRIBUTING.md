# Contributing

Follow the README to start Judge0. This guide is for changing the repository.

## Share a change

Collaborators with write access can create a branch in this repository. Other contributors should fork it on GitHub first and clone their fork. Then create a branch before editing:

```sh
git switch main
git pull --ff-only
git switch -c your-change
```

Edit the application in `judge0-src/`. It is part of this repository, not a separate checkout. The root `Dockerfile.arm64` and `docker-compose.yml` are the build and startup configuration. Keep supported languages in `judge0-src/db/seeds.rb` aligned with the compilers installed in `Dockerfile.arm64`. Gator++ uses C++ language id 54 with `/usr/bin/g++`; older GCC aliases are not supported.

Before committing, review `git diff`. Keep `.env` files, logs, generated files, and personal credentials out of commits. The checked-in `judge0.conf` contains shared local defaults; changes to it affect everyone's setup.

## Check your change

The source checks need Ruby 3.0 installed on your host. They use only its standard library and the host shell. Run them together:

```sh
sh scripts/check
```

GitHub runs the same command on pushes and pull requests. These checks cover source behavior; they do not compile a C++ submission in Docker.

For a runtime change, rebuild and wait for all services to be ready:

```sh
docker compose up -d --build --wait --wait-timeout 180
```

Run the C++ example in the README, then check submissions with stdin, an extra header file, compiler errors, and a time limit:

```sh
python3 checks/check_submission.py
```

This check needs Python 3 and Docker running. It uses only Python's standard library, submits four programs to the running local instance, and polls for their results, as the Gator++ backend does. It is separate from the source checks. Add cases when changing submission behavior that these examples do not cover.

If you change the precompiled header, stop sending submissions while running this additional check:

```sh
docker compose exec -T -u root worker sh -s < checks/check_pch.sh
```

Commit and push your branch, then open a pull request:

```sh
git add PATHS_YOU_CHANGED
git commit -m "Describe the change"
git push -u origin your-change
```

Explain what changed, why, and which checks you ran. Another collaborator should review the pull request before it is merged.

## Build dependencies and history

The Isolate sandbox source is pinned to a commit in `Dockerfile.arm64`. Change that commit deliberately and test a rebuild. Ubuntu packages and Docker image tags can still change over time, so builds are not guaranteed to be byte-for-byte identical.

`SOURCE_PROVENANCE.md` records the source origin and license. Preserve existing notices and add a dated modification note when changing upstream files. This project is a derivative of Judge0; it is not an official Judge0 release.
