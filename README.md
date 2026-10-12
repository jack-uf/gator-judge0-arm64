# Gator++ Judge0 for Apple Silicon

A self-contained ARM64 Judge0 stack for compiling and executing Gator++ C++ challenges on an Apple Silicon Mac. It includes the modified Judge0 Rails application, native Isolate sandbox, C++ compiler, API server, worker, PostgreSQL, and Redis.

## Requirements

- An Apple Silicon Mac (M-series). `uname -m` should print `arm64`.
- Docker Desktop installed and running, with Linux containers.
- Git and internet access for the first image build.
- Enough Docker memory for the build and services. The original development environment allocated about 8 GiB; this is a starting allocation, not a measured minimum.

This image is authored for ARM64. Intel Mac support has not been validated. You do not need Ruby, Rails, PostgreSQL, Redis, or a C++ compiler installed on the Mac to run the stack.

## Clone and start

```sh
git clone https://github.com/jack-uf/gator-judge0-arm64.git
cd gator-judge0-arm64
docker info
docker compose up -d --build
docker compose ps
```

The repository is private: collaborators need GitHub access before cloning. All required Judge0 application source is included in `judge0-src/`; no second clone or submodule command is needed. The first build downloads packages, installs Ruby gems, and compiles Isolate. Wait for the API to answer before testing a submission:

```sh
curl -fsS http://localhost:2358/languages
```

If it is not ready, inspect `docker compose logs --tail=100 server worker db redis`. The server initializes the database and language catalogue during startup.

## Verify compilation and execution

Find a C++ (GCC) entry in `/languages`. The bundled source seeds ID `54`; verify the actual response before using it. Then submit a small program:

```sh
curl -fsS -X POST \
  'http://localhost:2358/submissions?base64_encoded=false&wait=true' \
  -H 'Content-Type: application/json' \
  -d '{"language_id":54,"source_code":"#include <iostream>\nint main() { std::cout << \"Judge0 works!\"; }","expected_output":"Judge0 works!"}'
```

Success is `status.id: 3` (`Accepted`) and `stdout: "Judge0 works!"`. A successful `/languages` request only verifies the API, not compilation or sandbox execution. If the response is still queued or processing, use its token to retrieve the result:

```sh
curl -fsS 'http://localhost:2358/submissions/REPLACE_WITH_TOKEN?base64_encoded=false'
```

## Connect Gator++

For a Gator++ backend running directly on the same Mac, set these entries in its `.env`:

```dotenv
JUDGE0_BASE_URL=http://localhost:2358
JUDGE0_CPP_LANGUAGE_ID=54
JUDGE0_CPU_TIME_LIMIT_SECONDS=2
JUDGE0_WALL_TIME_LIMIT_SECONDS=5
JUDGE0_MEMORY_LIMIT_KB=128000
GRID_LOCAL_RUNNER=false
```

Use the language ID confirmed above, then restart the backend. Open Gator Phone → Grid challenges and run a challenge. Compiler errors should return diagnostics; a valid program should return an execution result.

Each collaborator runs this stack on their own Mac. Here `localhost` means that collaborator's machine. For a containerized backend, attach it to this Compose project's network and use `http://server:2358`; `localhost` inside that backend container points to the backend itself. Verify connectivity from the backend container before running a challenge.

## Daily commands

Run from the repository directory:

```sh
docker compose up -d                       # start existing images
docker compose logs -f server worker       # follow API and worker logs
docker compose restart server worker      # restart application services
docker compose down                       # stop; retain database volume
docker compose up -d --build               # rebuild after source/image changes
docker stats                              # inspect resource usage
```

PostgreSQL data lives in the named `postgres-data` volume. `docker compose down` keeps it. Removing that volume deletes the local submission database. Back up any data you need before deliberately resetting it.

## Troubleshooting

| Symptom | Check or recovery |
| --- | --- |
| Docker daemon connection fails | Open Docker Desktop, wait for startup, and rerun `docker info`. |
| Port 2358 is already allocated | Another judge may be running. Stop its Compose project, or change this project's host port and update the backend URL to match. |
| Build cannot find `judge0-src/Gemfile` | Check that you cloned this repository and are running commands at its root. The source directory must be present. |
| API is not ready | Inspect server and database logs; initial database setup can take time. |
| Submission stays queued | Inspect worker logs and `docker compose ps`. Both API and worker services must be running. |
| Submission reports Internal Error | Inspect worker logs for the sandbox error. Confirm the image is `judge0:arm64-native` and the worker uses this repository's Isolate wrapper. |
| Unsupported language | This image primarily ships a C/C++ toolchain. An advertised language label does not install another compiler. Check the seed and Dockerfile before expanding the supported set. |

## Local development boundaries

The API binds to `127.0.0.1:2358` by default. Its bundled passwords are development defaults, and API authentication is unset. This is a local development distribution, not a configured public judging service. The worker is privileged because Isolate needs sandbox setup privileges; the API service is unprivileged.

The Isolate wrapper replaces unsupported cgroup flags with resource-limit equivalents. This differs from upstream cgroup accounting and should be assessed before hosting untrusted submissions for a class. To host a shared service, configure authentication, network access, passwords, and the execution host deliberately. Redis's command-line password in `docker-compose.yml` must match `REDIS_PASSWORD` if you change it.

## Checks and maintenance

With Ruby and Python installed on the host, run the source checks listed below. The wrapper check uses the host shell. These checks do not prove that Docker compilation works: also perform the submission test above.

```sh
ruby checks/check_exec_plan.rb
ruby checks/check_compilation_cache.rb
ruby checks/check_sandbox_argv.rb
ruby checks/check_base64_service.rb
ruby checks/check_wait_budget.rb
sh checks/check_isolate_wrapper.sh
ruby checks/check_language_seed.rb
ruby checks/check_pch.rb
python3 checks/check_saturation_sampler.py
python3 checks/check_pool_structure.py
```

For a container-level precompiled-header check, run while no submission is in flight:

```sh
docker compose exec -T -u root worker sh -s < checks/check_pch.sh
```

See [SOURCE_PROVENANCE.md](SOURCE_PROVENANCE.md) for the exported fork revision and licensing, and [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) for benchmark methods, results, and limitations.
