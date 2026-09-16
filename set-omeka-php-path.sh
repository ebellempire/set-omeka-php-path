#!/usr/bin/env bash
#
# set-omeka-php-path.sh
#
# Sets background.php.path in each Omeka Classic installation's application/config/config.ini to the PHP CLI binary matching that site's PHP version, e.g. /usr/local/bin/ea-php82 on cPanel/EasyApache 4.
#
#   bash set-omeka-php-path.sh path/to/omeka
#   bash set-omeka-php-path.sh path/to/omeka another/path/to/omeka
#   bash set-omeka-php-path.sh -n path/to/omeka # dry run
#   bash set-omeka-php-path.sh -b ea-php74 path/to/omeka
#
# Finding the path: `php` is run from inside each installation. On cPanel, /usr/local/bin/php is the ea-php-cli wrapper. It picks the PHP version of the vhost whose document root contains the current directory (MultiPHP Manager), else the system default, and execs /opt/cpanel/ea-phpNN/root/usr/bin/php. That is mapped to the /usr/local/bin/ea-phpNN symlink. (/usr/bin/php on cPanel is the php-cgi wrapper, so it is never used.)
#
# Editing the file: awk rewrites only the background.php.path line(s), or adds one under [site], in a temp copy. PHP's parse_ini_file() (what Zend_Config_Ini uses to load it) must show the new value and every other setting unchanged before the original is backed up and overwritten in place. Backups are named config.bak-YYYYmmdd-HHMMSS.ini because Omeka's .htaccess denies *.ini but serves other files, so a config.ini.bak would be downloadable.

SUMMARY=''
NOW=$(date +"%Y%m%d-%H%M%S")
SCRIPT_LOCATION=$(pwd)
ME="${0##*/}"
KEY=background.php.path
WRAPPER=/usr/local/bin/php
DRY_RUN=0
OVERRIDE=''
FAILED=0

RED='\E[0;31m'
GREEN='\E[0;32m'
YELLOW='\E[0;33m'
CYAN='\E[0;36m'
NOCOLOR='\E[0m'
BOLD=$(tput bold 2>/dev/null)
NORMAL=$(tput sgr0 2>/dev/null)

usage() {
	echo -e "Include at least one path to an existing Omeka installation. Here's an example: \n${YELLOW}bash ${ME} path/to/omeka1 path/to/omeka2${NOCOLOR}"
	echo -e "Options (before the paths):\n  -n          dry run: report what would change, write nothing\n  -b PHP_BIN  skip detection and use this binary (absolute path or ea-phpNN)"
}

# add_summary COLOR MARK SITE DETAIL... (also appends the site's WARNINGS)
add_summary() {
	local COLOR=$1 MARK=$2 SITE=$3 LINE
	shift 3
	SUMMARY+="\n${COLOR}${BOLD}${MARK} ${SITE}:${NORMAL}${NOCOLOR}\n"
	for LINE in "$@"; do
		SUMMARY+="  ➡ ${LINE}\n"
	done
	for LINE in "${WARNINGS[@]}"; do
		SUMMARY+="  ➡ ${YELLOW}Warning: ${LINE}${NOCOLOR}\n"
	done
}

site_error() {
	echo -e "${RED}█ ERROR: $2${NOCOLOR}"
	add_summary "$RED" "✗" "$1" "$2"
	FAILED=1
}

# Omeka's own check (_checkCliPath) only wants exit 0 and a first line like "PHP 8.2.1", so it accepts php-cgi. Also require the CLI SAPI. Prints version.
cli_version() {
	local OUT RE='^PHP ([0-9][0-9.]*) \(cli\)'
	OUT=$("$1" -v 2>/dev/null) || return 1
	[[ ${OUT%%$'\n'*} =~ $RE ]] || return 1
	echo "${BASH_REMATCH[1]}"
}

# detect_php ROOT: sets PHP_BIN (and PHP_PKG on cPanel), or ERR and returns 1.
detect_php() {
	local ROOT=$1 REAL STDERR RE='^/opt/cpanel/(ea-php[0-9]+)/root/usr/bin/php$'
	PHP_BIN='' PHP_PKG=''
	REAL=$(cd -- "$ROOT" && "$DETECT_PHP" -n -r 'echo PHP_BINARY;' 2>"$WORK_DIR/stderr")
	STDERR=$(head -n 1 "$WORK_DIR/stderr")
	if [[ $REAL != /* ]]; then
		ERR="Could not run ${DETECT_PHP} in this directory${STDERR:+: ${STDERR}}"
		return 1
	fi
	# ea-php-cli says this when the vhost's PHP version has no CLI package.
	if [[ $STDERR == *'using default'* ]]; then
		ERR="${STDERR} (install that version's php-cli package, or use -b)"
		return 1
	fi
	[ -z "$STDERR" ] || WARNINGS+=("${DETECT_PHP}: ${STDERR}")
	PHP_BIN=$REAL
	if [[ $REAL =~ $RE ]]; then
		PHP_PKG=${BASH_REMATCH[1]}
		if [ -x "/usr/local/bin/${PHP_PKG}" ]; then PHP_BIN=/usr/local/bin/${PHP_PKG}; fi
	fi
	return 0
}

# The wrapper ignores .htaccess, so flag a nearer hand-added handler that names a different ea-php version than the vhost does.
check_htaccess() {
	local DIR=$1 HIT
	while :; do
		if [ -r "${DIR}/.htaccess" ]; then
			HIT=$(grep -Eo '^[[:space:]]*(AddHandler|AddType|SetHandler)[[:space:]]+"?application/x-httpd-ea-php[0-9]+' \
				"${DIR}/.htaccess" | tail -n 1)
			if [ -n "$HIT" ]; then
				HIT=${HIT##*x-httpd-}
				[ "$HIT" = "$PHP_PKG" ] ||
					WARNINGS+=("${DIR}/.htaccess sets ${HIT} but the vhost uses ${PHP_PKG}; if that handler is active, rerun with -b ${HIT}")
				return 0
			fi
		fi
		[ "$DIR" = / ] && return 0
		DIR=${DIR%/*}
		DIR=${DIR:-/}
	done
}

# php_ini get FILE: print [site] background.php.path
# php_ini check OLD NEW EXPECTED: NEW parses, has EXPECTED, and everything else matches OLD
php_ini() {
	# shellcheck disable=SC2016  # PHP code, not shell
	"$PHP_BIN" -n -d display_errors=stderr -r '
		$k = "background.php.path";
		$old = @parse_ini_file($argv[2], true);
		if ($old === false) exit(2);
		if ($argv[1] === "get") { echo isset($old["site"][$k]) ? $old["site"][$k] : ""; exit(0); }
		$new = @parse_ini_file($argv[3], true);
		if ($new === false) exit(3);
		if (!isset($new["site"][$k]) || $new["site"][$k] !== $argv[4]) exit(4);
		unset($old["site"][$k], $new["site"][$k]);
		exit($old === $new ? 0 : 5);
	' "$@"
}

# ini_edit FILE MODE: print FILE with each background.php.path line replaced, or with MODE=insert, a new line right after [site]. Keeps CRLF endings.
ini_edit() {
	LINE="${KEY} = \"${PHP_BIN}\"" MODE=$2 awk '
		BEGIN { line = ENVIRON["LINE"]; insert = (ENVIRON["MODE"] == "insert") }
		{ cr = ($0 ~ /\r$/) ? "\r" : "" }
		!insert && /^[ \t]*background\.php\.path[ \t]*=/ { print line cr; next }
		{ print }
		insert && !done && /^[ \t]*\[site\][ \t\r]*$/ { print line cr; done = 1 }
		END { if (insert && !done) exit 1 }
	' "$1"
}

# update_site SITE: detect, validate and write; adds the site's summary entry.
update_site() {
	local SITE=$1 ROOT CONFIG CLI CURRENT FROM MODE BACKUP N=1 WARNING
	ROOT=$(cd -- "$SITE" && pwd) || { site_error "$SITE" "Could not enter ${SITE}"; return; }
	CONFIG=${ROOT}/application/config/config.ini
	[ -f "$CONFIG" ] || { site_error "$SITE" "No application/config/config.ini"; return; }

	if [ -n "$OVERRIDE" ]; then
		PHP_BIN=$OVERRIDE PHP_PKG=''
	else
		echo -e "${CYAN}█ Detecting the site's PHP version ...${NOCOLOR}"
		detect_php "$ROOT" || { site_error "$SITE" "$ERR"; return; }
		[ -z "$PHP_PKG" ] || check_htaccess "$ROOT"
	fi
	CLI=$(cli_version "$PHP_BIN") ||
		{ site_error "$SITE" "${PHP_BIN} is not a working PHP CLI binary (php -v must say (cli))"; return; }
	case $PHP_BIN in *'"'* | *$'\n'*) site_error "$SITE" "Refusing to write a path with quotes or newlines"; return ;; esac
	echo -e "${CYAN}█ PHP ${CLI} CLI: ${PHP_BIN}${NOCOLOR}"
	for WARNING in "${WARNINGS[@]}"; do
		echo -e "${YELLOW}█ Warning: ${WARNING}${NOCOLOR}"
	done

	CURRENT=$(php_ini get "$CONFIG") ||
		{ site_error "$SITE" "PHP cannot parse config.ini as it stands; fix that by hand first"; return; }
	if grep -Eq '^[[:space:]]*background\.php\.path[[:space:]]*=' "$CONFIG"; then
		if [ "$CURRENT" = "$PHP_BIN" ]; then
			echo -e "${CYAN}█ ${KEY} is already set; nothing to do${NOCOLOR}"
			add_summary "$GREEN" "✔" "$SITE" "Already set: ${KEY} = \"${PHP_BIN}\" (PHP ${CLI})"
			return
		fi
		FROM="\"${CURRENT}\"" MODE=replace
	else
		FROM="(not set)" MODE=insert
	fi

	if [ "$DRY_RUN" = 1 ]; then
		add_summary "$GREEN" "✔" "$SITE" "Dry run: would change ${KEY} from ${FROM} to \"${PHP_BIN}\" (PHP ${CLI})"
		return
	fi
	[ -w "$CONFIG" ] || { site_error "$SITE" "config.ini is not writable"; return; }

	echo -e "${CYAN}█ Updating application/config/config.ini ...${NOCOLOR}"
	ini_edit "$CONFIG" "$MODE" >"$WORK_DIR/new" ||
		{ site_error "$SITE" "config.ini has no [site] section"; return; }
	php_ini check "$CONFIG" "$WORK_DIR/new" "$PHP_BIN"
	case $? in
		0) ;;
		5) site_error "$SITE" "The edit would also change other settings (is ${KEY} set outside [site]?); config.ini left untouched"; return ;;
		*) site_error "$SITE" "The edited copy did not validate; config.ini left untouched"; return ;;
	esac

	BACKUP=${CONFIG%/*}/config.bak-${NOW}.ini
	while [ -e "$BACKUP" ]; do BACKUP=${CONFIG%/*}/config.bak-${NOW}-$((N++)).ini; done
	cp -p -- "$CONFIG" "$BACKUP" || { site_error "$SITE" "Could not create backup ${BACKUP}"; return; }

	# Write into the existing file (no rename) so owner, mode and inode stay put.
	if ! cat -- "$WORK_DIR/new" >"$CONFIG" || ! php_ini check "$BACKUP" "$CONFIG" "$PHP_BIN"; then
		cat -- "$BACKUP" >"$CONFIG"
		site_error "$SITE" "Write failed; restored config.ini from ${BACKUP##*/}"
		return
	fi
	add_summary "$GREEN" "✔" "$SITE" "Changed ${KEY} from ${FROM} to \"${PHP_BIN}\" (PHP ${CLI})" "Backup: ${BACKUP}"
}

while getopts ':nb:h' OPT; do
	case $OPT in
		n) DRY_RUN=1 ;;
		b) OVERRIDE=$OPTARG ;;
		h) usage; exit 0 ;;
		:) echo -e "${RED}█ Option -${OPTARG} needs a value${NOCOLOR}"; usage; exit 1 ;;
		*) echo -e "${RED}█ Unknown option -${OPTARG}${NOCOLOR}"; usage; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

if [ $# -eq 0 ]; then
	echo -e "${RED}█ Oops, you forgot to include an argument! ${NOCOLOR}"
	usage
	exit 1
fi

echo -e "${CYAN}Running ${ME} from ${SCRIPT_LOCATION}${NOCOLOR}"

# PHP used for detection (or the -b binary), like the utility's git check
if [ -n "$OVERRIDE" ]; then
	if [[ $OVERRIDE =~ ^ea-php[0-9]+$ ]]; then OVERRIDE=/usr/local/bin/${OVERRIDE}; fi
	if [[ $OVERRIDE != /* ]] || ! CLI=$(cli_version "$OVERRIDE"); then
		echo -e "${RED}█ ERROR: -b must be the absolute path of a PHP CLI binary (or ea-phpNN); got '${OVERRIDE}'${NOCOLOR}"
		exit 1
	fi
	echo -e "${GREEN}█ PHP ${CLI} CLI verified (${OVERRIDE}); skipping detection${NOCOLOR}"
elif [ -x "$WRAPPER" ]; then
	DETECT_PHP=$WRAPPER
	echo -e "${GREEN}█ PHP wrapper verified (${WRAPPER})${NOCOLOR}"
elif DETECT_PHP=$(command -v php); then
	echo -e "${YELLOW}█ cPanel's ${WRAPPER} not found; detecting with ${DETECT_PHP} (use -b if that is not the site's PHP)${NOCOLOR}"
else
	echo -e "${RED}█ ERROR: PHP is missing or is not executable. Use -b to set the PHP binary.${NOCOLOR}"
	exit 1
fi
[ "$DRY_RUN" = 1 ] && echo -e "${GREEN}█ Dry run: no files will be changed${NOCOLOR}"

WORK_DIR=$(mktemp -d) || { echo -e "${RED}█ Unable to create a temporary directory${NOCOLOR}"; exit 2; }
trap 'rm -rf -- "$WORK_DIR"' EXIT

for SITE_RAW in "$@"; do
	SITE="${SITE_RAW%/}"
	WARNINGS=()
	if [ -e "${SITE}/bootstrap.php" ] && grep -q OMEKA_VERSION "${SITE}/bootstrap.php"; then
		echo -e "${GREEN}\n█ Omeka installation found at ${SITE}\n${NOCOLOR}"
		update_site "$SITE"
	else
		echo -e "${YELLOW}\n█ Omeka installation not found at ${SITE}. Skipping this directory.\n${NOCOLOR}"
		add_summary "$YELLOW" "✗" "$SITE" "Skipped (not an Omeka installation)"
	fi
done

printf '%*s\n' "${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}" '' | tr ' ' -
echo -e "${CYAN}\n\n${SUMMARY}\n\n${NOCOLOR}"
printf '%*s\n' "${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}" '' | tr ' ' -
exit "$FAILED"
