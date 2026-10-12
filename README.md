# Gator++ Judge0 for Apple Silicon

Run Gator++ C++ challenges locally on an Apple Silicon Mac using Judge0 and Docker Desktop.

## What you need

- An Apple Silicon Mac (M1 or newer).
- Docker Desktop installed and running.
- Git and an internet connection for the first build.

Everything else is included. You do not need to install Ruby, a compiler, or a database on your Mac.

## Start Judge0

Clone the repository and start it:

```sh
git clone https://github.com/jack-uf/gator-judge0-arm64.git
cd gator-judge0-arm64
docker compose up -d --build
```

The first build takes a few minutes. Once it finishes, check that Judge0 responds:

```sh
curl -fsS http://localhost:2358/languages
```

You should see a list of supported languages. If the connection fails, wait a moment and try again.

## Connect Gator++

Add these settings to your Gator++ backend's `.env` file:

```dotenv
JUDGE0_BASE_URL=http://localhost:2358
JUDGE0_CPP_LANGUAGE_ID=54
JUDGE0_CPU_TIME_LIMIT_SECONDS=2
JUDGE0_WALL_TIME_LIMIT_SECONDS=5
JUDGE0_MEMORY_LIMIT_KB=128000
GRID_LOCAL_RUNNER=false
```

Restart the backend, then open Gator Phone → Grid challenges and run a challenge.

Each collaborator starts Judge0 on their own Mac. These settings assume the backend runs directly on that same Mac. If the backend also runs in Docker, connect it to Judge0's Docker network and use `http://server:2358` instead.

## Try a C++ program

To test Judge0 without opening Gator++, run:

```sh
curl -fsS -X POST \
  'http://localhost:2358/submissions?base64_encoded=false&wait=true' \
  -H 'Content-Type: application/json' \
  -d '{"language_id":54,"source_code":"#include <iostream>\nint main() { std::cout << \"Judge0 works!\"; }","expected_output":"Judge0 works!"}'
```

The response should contain `"stdout": "Judge0 works!"` and a status of `Accepted`.

## Stop, restart, or update

Run these commands from the repository folder:

```sh
docker compose down                 # stop Judge0; keep saved submissions
docker compose up -d                # start it again
git pull                            # get the latest repository changes
docker compose up -d --build        # rebuild and start after an update
```

## If something goes wrong

Check which services are running and view their recent logs:

```sh
docker compose ps
docker compose logs --tail=100 server worker db redis
```

- **Docker cannot connect:** open Docker Desktop and wait for it to finish starting.
- **Port 2358 is already in use:** stop the other Judge0 instance before starting this one.
- **Judge0 responds, but a submission stays queued:** check the worker logs for an error.
- **Gator++ cannot connect:** confirm the backend settings above and restart the backend.

This setup is for local use. It listens at `http://localhost:2358` and has no API authentication configured.

## License

GPL-3.0. Based on [Judge0](https://github.com/judge0/judge0). See [LICENSE](LICENSE) and [SOURCE_PROVENANCE.md](SOURCE_PROVENANCE.md) for licensing and source details.
