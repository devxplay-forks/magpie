#!/usr/bin/env bash
# `./run-web.sh`: build magpie from this checkout, make the `magpie` command
# that build, then serve the web UI and the gateway. Nothing to type but the
# script: no `go run` line to remember, no command to repair by hand.
#
# Why the command is a link: magpie's window tells the user when `magpie`
# in ~/.local/bin is a copied file rather than install.sh's link into the
# app, because a copy goes on running its own build — and its own
# migrations — once the app has moved on (update.CopiedCLI, #531).
# `go run` can't be linked: it builds into a temporary folder and deletes it
# when it exits. So this builds once to a folder that stays, links that, and
# serves it. Every run rebuilds, so the command is as new as the checkout.
#
# Options:
#   --port <n>          the page's port (3430, as `magpie web`)
#   --gateway-port <n>  the gateway's port (3425)
#   --addr <host:port>  where the page listens (127.0.0.1:<port>)
#   --lan               serve the page and the gateway on the network
#                       (0.0.0.0): anyone with the link can change magpie
#   --web-key <key>     the page's key, kept across runs, as MAGPIE_WEB_KEY
#                       does; without one, each run makes its own and prints
#                       the link that carries it
#   --use-proxy         keep HTTP_PROXY and friends: they are bypassed by
#                       default, so magpie reaches the vendors directly
#   --no-link           build and serve, leave the `magpie` command alone
#   --setup-only        build and link, don't serve
#   --no-open           don't open the page in a browser
#   --no-log            don't keep the run's output in a log file
#   --                  the rest is passed to `magpie web`
#
# MAGPIE_BIN_DIR says where the command goes, as install.sh honors it.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

port=3430
gateway_port=3425
addr=''
lan=0
web_key=''
use_proxy=0
link=1
serve=1
open_page=1
keep_log=1
log_file="${MAGPIE_LOG:-/tmp/magpie.log}"
rest=()

say() { printf '  %s\n' "$*"; }
die() { printf 'magpie: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--port) [ $# -ge 2 ] || die "--port needs a value"; port=$2; shift 2 ;;
	--port=*) port=${1#--port=}; shift ;;
	--gateway-port) [ $# -ge 2 ] || die "--gateway-port needs a value"; gateway_port=$2; shift 2 ;;
	--gateway-port=*) gateway_port=${1#--gateway-port=}; shift ;;
	--addr) [ $# -ge 2 ] || die "--addr needs host:port"; addr=$2; shift 2 ;;
	--addr=*) addr=${1#--addr=}; shift ;;
	--lan) lan=1; shift ;;
	--web-key) [ $# -ge 2 ] || die "--web-key needs a value"; web_key=$2; shift 2 ;;
	--web-key=*) web_key=${1#--web-key=}; shift ;;
	--use-proxy) use_proxy=1; shift ;;
	--no-link) link=0; shift ;;
	--setup-only) serve=0; shift ;;
	--no-open) open_page=0; shift ;;
	--no-log) keep_log=0; shift ;;
	--)
		shift
		while [ $# -gt 0 ]; do rest+=("$1"); shift; done ;;
	-h | --help)
		awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
		exit 0 ;;
	*) die "unknown option $1 (--help lists them)" ;;
	esac
done

# Direct to the vendors unless asked otherwise, as run-web.ps1 does: a proxy
# in the environment sends magpie's own requests somewhere its accounts'
# sign-ins weren't made from.
if [ "$use_proxy" -eq 0 ]; then
	unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
	export NO_PROXY='*' no_proxy='*'
fi

command -v go >/dev/null 2>&1 || die "no go on PATH: install Go (https://go.dev/dl), which builds magpie from this checkout"

# The build lives outside magpie's own folders (.config/magpie,
# .local/share/magpie): this is a program, not the user's data.
data_dir=${XDG_DATA_HOME:-$HOME/.local/share}
build_dir="$data_dir/magpie-dev"
exe="$build_dir/magpie"
bin_dir=${MAGPIE_BIN_DIR:-$HOME/.local/bin}
cli="$bin_dir/magpie"

mkdir -p "$build_dir" || die "could not make $build_dir"

printf '  building magpie (nogui) from %s\n' "$PWD"
# to a new file first, moved in when it built: a failed build leaves the
# last one working, and a running magpie keeps the file it is running
if ! go build -tags nogui -o "$exe.new" .; then
	rm -f "$exe.new"
	die "go build failed: nothing was replaced, $exe is the last build that worked"
fi
chmod +x "$exe.new" || die "could not make $exe.new executable"
mv -f "$exe.new" "$exe" || die "could not put the new build at $exe"

if [ "$link" -eq 1 ]; then
	mkdir -p "$bin_dir" || die "could not make $bin_dir"
	if [ -L "$cli" ] && [ "$(readlink "$cli")" = "$exe" ]; then
		say "the magpie command already points at this build"
	else
		if [ -e "$cli" ] || [ -L "$cli" ]; then
			# a copy — an older installer, a hand cp, a standalone build — or
			# the installer's own link into an app that isn't this checkout:
			# kept aside once, so nothing of the user's is lost
			if [ -e "$cli.old" ] || [ -L "$cli.old" ]; then
				rm -f "$cli" || die "could not replace $cli"
				say "replaced the file at $cli"
			else
				mv "$cli" "$cli.old" || die "could not move $cli aside"
				say "moved the file at $cli aside, to $cli.old"
			fi
		fi
		ln -sfn "$exe" "$cli" || die "could not link $cli to $exe"
		say "the magpie command is $cli → $exe"
	fi
	case ":$PATH:" in
	*":$bin_dir:"*) ;;
	*) say "note: $bin_dir isn't on PATH: add it to a shell's profile to run magpie as a command" ;;
	esac
fi

if [ "$serve" -eq 0 ]; then
	say "set up: $exe is built and $( [ "$link" -eq 1 ] && printf 'linked' || printf 'not linked' )"
	exit 0
fi

# The gateway's address: MAGPIE_ADDR unless this run sets one. On the
# network it is 0.0.0.0, which needs a key for the other machines.
if [ -z "${MAGPIE_ADDR:-}" ]; then
	if [ "$lan" -eq 1 ]; then
		export MAGPIE_ADDR="0.0.0.0:$gateway_port"
	elif [ "$gateway_port" != 3425 ]; then
		export MAGPIE_ADDR="127.0.0.1:$gateway_port"
	fi
fi

if [ -n "$web_key" ]; then
	export MAGPIE_WEB_KEY="$web_key"
fi

# Another machine can only call a shared gateway with a key, and the page
# needs one of its own: the link `magpie web` prints carries it.
if [ "$lan" -eq 1 ]; then
	keys=$("$exe" gateway-key list 2>/dev/null | tail -n +2 | grep -c . || true)
	if [ "${keys:-0}" -eq 0 ]; then
		say "making a gateway key for the other machines: lan-client"
		"$exe" gateway-key add lan-client >/dev/null || die "could not make a gateway key"
	fi
fi

page_addr=$addr
if [ -z "$page_addr" ]; then
	if [ "$lan" -eq 1 ]; then page_addr="0.0.0.0:$port"; else page_addr="127.0.0.1:$port"; fi
fi

web_args=(web --addr "$page_addr")
if [ "$open_page" -eq 0 ]; then web_args+=(--no-open); fi
if [ ${#rest[@]} -gt 0 ]; then web_args+=("${rest[@]}"); fi

say "web on http://$page_addr · gateway on ${MAGPIE_ADDR:-127.0.0.1:3425} · Ctrl-C to stop"
if [ "$keep_log" -eq 1 ]; then
	say "output also kept in $log_file"
	set -o pipefail
	"$exe" "${web_args[@]}" 2>&1 | tee "$log_file"
	exit "${PIPESTATUS[0]}"
fi
exec "$exe" "${web_args[@]}"
