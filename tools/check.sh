#!/usr/bin/env bash
# Loom, by SpaceCrafter29 -- https://github.com/SpaceCrafter29/loom
# Static checks for the Loom repo. Runs anywhere bash does -- no Arch, no root,
# no container -- which makes it the one thing that can be run on a laptop that
# is not the target machine.
#
# It is not a substitute for booting the ISO. It catches the failures that are
# expensive precisely because they only show up at boot: a CRLF in an initramfs
# hook, a profiledef entry pointing at a file that was renamed, a package list
# with a duplicate, a loomctl subcommand in the help text that no longer exists.

set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

if [[ -t 1 ]]; then
    R=$'\033[0m'; B=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'
else
    R=''; B=''; RED=''; GRN=''; YEL=''; DIM=''
fi

FAILURES=0
WARNINGS=0

group() { printf '\n%s== %s%s\n' "$B" "$1" "$R"; }
pass()  { printf '  %s+%s %s\n' "$GRN" "$R" "$*"; }
fail()  { printf '  %sx%s %s\n' "$RED" "$R" "$*"; FAILURES=$((FAILURES + 1)); }
warn()  { printf '  %s!%s %s\n' "$YEL" "$R" "$*"; WARNINGS=$((WARNINGS + 1)); }
info()  { printf '  %s.%s %s\n' "$DIM" "$R" "$*"; }

# Every file in the repo that is a shell script, by shebang or by location.
shell_files() {
    {
        find . -path ./build -prune -o -path ./out -prune -o -type f \
            \( -name '*.sh' -o -name '*.bash' -o -name 'PKGBUILD' -o -name 'profiledef.sh' \) -print
        find ./rootfs/usr/local/bin ./iso/airootfs/usr/local/bin -type f 2>/dev/null
        find ./rootfs/etc/initcpio -type f 2>/dev/null
        printf '%s\n' ./rootfs/etc/profile.d/loom-session.sh ./rootfs/etc/profile.d/loom-env.sh
        printf '%s\n' ./iso/airootfs/root/.bash_profile
    } | sort -u | while read -r f; do
        [[ -f $f ]] && printf '%s\n' "$f"
    done
}

# --- 1. line endings ---------------------------------------------------------

has_cr() {
    # Strip every CR and compare with the original. No regex, no locale, no
    # text/binary mode guessing -- `grep $'\r'` is unreliable under MSYS, which
    # is exactly the platform where a CR is most likely to have crept in.
    ! LC_ALL=C tr -d '\r' <"$1" | cmp -s - "$1"
}

check_crlf() {
    group "line endings"
    local f n=0
    local -a bad=()
    while read -r f; do
        case "$f" in *.psf|*.psfu|*.png|*.gz|*.zst|*.iso) continue ;; esac
        n=$((n + 1))
        has_cr "$f" && bad+=("$f")
    done < <(find . -path ./build -prune -o -path ./out -prune -o -path ./.git -prune \
                 -o -type f -print)

    if (( ${#bad[@]} == 0 )); then
        pass "$n text file(s), none with CR"
    else
        fail "${#bad[@]} file(s) contain CR -- a shell script or initramfs hook with"
        info "      CRLF fails at boot with 'bad interpreter', or silently does nothing:"
        printf '        %s\n' "${bad[@]}"
    fi
}

# --- 2. shell syntax ---------------------------------------------------------

check_syntax() {
    group "shell syntax (bash -n)"
    local f n=0
    while read -r f; do
        # The fish and ash files are not bash; skip them here.
        case "$f" in *.fish) continue ;; esac
        if [[ $(head -n1 "$f") == '#!/usr/bin/ash' ]]; then
            info "skipped $f (ash, checked separately)"
            continue
        fi
        if bash -n "$f" 2>/tmp/loom-check-err; then
            n=$((n + 1))
        else
            fail "$f"
            sed 's/^/        /' /tmp/loom-check-err
        fi
    done < <(shell_files)
    rm -f /tmp/loom-check-err
    pass "$n shell file(s) parse"
}

check_shellcheck() {
    group "shellcheck"
    if ! command -v shellcheck >/dev/null 2>&1; then
        warn "shellcheck is not installed; skipping (pacman -S shellcheck)"
        return 0
    fi
    # -x with source-path=SCRIPTDIR makes shellcheck actually read lib/common.sh
    # instead of guessing at it. Without that, every colour variable and helper
    # function defined there looks undefined in the scripts that source it, and
    # the real findings drown in false positives.
    local -a args=(-s bash -S warning -x --source-path=SCRIPTDIR --source-path="$REPO/scripts" -e SC1091)

    local f issues=0
    while read -r f; do
        case "$f" in
            *.fish) continue ;;
            # PKGBUILD is a makepkg data file, not a program. makepkg injects
            # $pkgdir and $srcdir and reads the metadata variables itself, so
            # shellcheck sees nothing but unused assignments and undefined
            # references. bash -n still checks it for syntax.
            */PKGBUILD) continue ;;
        esac
        [[ $(head -n1 "$f") == '#!/usr/bin/ash' ]] && continue
        if ! shellcheck "${args[@]}" "$f"; then
            issues=$((issues + 1))
        fi
    done < <(shell_files)

    if (( issues == 0 )); then
        pass "clean at severity >= warning"
    else
        # Advisory, not a gate. shellcheck's warning set grows with every
        # release, so gating on it means a new shellcheck version can fail CI on
        # a commit that changed nothing. The checks that genuinely brick a boot
        # -- CRLF, missing files, broken cross-references -- fail hard above.
        warn "$issues file(s) have shellcheck findings, listed above"
        info "advisory: shellcheck does not fail this run. Fix them anyway."
    fi
}

# --- 3. executable bits ------------------------------------------------------

check_exec_bits() {
    group "executable bits"
    local -a must_exec=(
        scripts/bootstrap.sh
        scripts/build-iso.sh
        tools/check.sh
        iso/airootfs/usr/local/bin/loom-install
        rootfs/usr/local/bin/loomctl
        rootfs/usr/local/bin/loom-session
        rootfs/usr/local/bin/loom-gui
        rootfs/usr/local/bin/loom-sign-boot
        rootfs/usr/local/bin/loom-build-rescue
        rootfs/usr/share/loom/rescue/rescue.sh
        rootfs/etc/initcpio/install/loom-rescue
        rootfs/etc/initcpio/hooks/loom-rescue
    )
    local f missing=0 nonexec=0
    for f in "${must_exec[@]}"; do
        if [[ ! -f $f ]]; then
            fail "missing: $f"
            missing=$((missing + 1))
        elif [[ ! -x $f ]]; then
            # On a Windows checkout this is expected: build-iso.sh and
            # bootstrap.sh both chmod on the way in.
            warn "not executable in the working tree: $f"
            nonexec=$((nonexec + 1))
        fi
    done
    (( missing == 0 )) && pass "all ${#must_exec[@]} expected scripts are present"
    (( nonexec > 0 )) && info "build-iso.sh and bootstrap.sh set these modes themselves"
    return 0
}

# --- 4. package lists --------------------------------------------------------

check_package_lists() {
    group "package lists"
    local f total=0
    local -a all=()
    for f in packages/*.txt; do
        [[ -f $f ]] || continue
        local -a pkgs=()
        mapfile -t pkgs < <(sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e '/^$/d' "$f")
        total=$((total + ${#pkgs[@]}))
        all+=("${pkgs[@]}")

        # A package name with whitespace in it means a list line got mangled.
        local p
        for p in "${pkgs[@]}"; do
            if [[ $p =~ [[:space:]] ]]; then
                fail "$f: '$p' contains whitespace"
            elif [[ ! $p =~ ^[a-z0-9@._+-]+$ ]]; then
                fail "$f: '$p' is not a plausible package name"
            elif [[ $p == *_* ]]; then
                # Arch separates words with hyphens. An underscore is almost
                # always a name typed from memory rather than copied -- this
                # cost three CI rounds once already (wireless_regdb).
                warn "$f: '$p' contains an underscore; Arch names use hyphens"
                info "      check it with: pacman -Ss '^${p//_/[-_]}\$'"
            fi
        done
        info "$(printf '%-22s %3d packages' "$(basename "$f")" "${#pkgs[@]}")"
    done

    # aur.txt is allowed to overlap nothing; the repo groups must not overlap
    # each other, or pacman gets the same name twice.
    local -a dupes=()
    mapfile -t dupes < <(printf '%s\n' "${all[@]}" | sort | uniq -d)
    if (( ${#dupes[@]} > 0 )); then
        warn "listed in more than one group: ${dupes[*]}"
        info "      harmless for pacman, but it means two groups own the same package"
    else
        pass "no package appears in two groups"
    fi
    pass "$total package entries total"
}

# --- 5. profiledef consistency ----------------------------------------------

check_profiledef() {
    group "archiso profiledef"
    local pd="iso/profiledef.sh"
    [[ -f $pd ]] || { fail "$pd is missing"; return 0; }

    # Every file_permissions entry must exist, either in the profile's airootfs
    # or in the payload that build-iso.sh injects. mkarchiso chmods these by
    # path and fails the build if one is absent.
    local path rel found=0 bad=0
    while read -r path; do
        [[ -z $path ]] && continue
        found=$((found + 1))
        rel="iso/airootfs$path"
        if [[ -e $rel ]]; then
            continue
        fi
        # Paths under /usr/share/loom-payload come from the repo root.
        if [[ $path == /usr/share/loom-payload/* ]]; then
            if [[ -e ${path#/usr/share/loom-payload/} ]]; then
                continue
            fi
        fi
        # /etc/shadow and friends are created by pacstrap inside the image.
        case "$path" in
            /etc/shadow|/etc/gshadow|/root) continue ;;
        esac
        fail "file_permissions references a path that does not exist: $path"
        bad=$((bad + 1))
    done < <(sed -n 's/^[[:space:]]*\["\([^"]*\)"\]=.*/\1/p' "$pd")
    (( bad == 0 )) && pass "all $found file_permissions entries resolve"

    # Each systemd-boot entry must point at a kernel path archiso will create.
    local e
    for e in iso/efiboot/loader/entries/*.conf; do
        [[ -f $e ]] || continue
        grep -q '%INSTALL_DIR%' "$e" || fail "$(basename "$e"): no %INSTALL_DIR% substitution"
    done
    local default_entry
    default_entry=$(sed -n 's/^default[[:space:]]*//p' iso/efiboot/loader/loader.conf 2>/dev/null)
    if [[ -n $default_entry && ! -f iso/efiboot/loader/entries/$default_entry ]]; then
        fail "loader.conf default '$default_entry' has no matching entry file"
    else
        pass "boot entries and loader.conf agree"
    fi
}

# --- 6. rootfs references ----------------------------------------------------

# mkarchiso needs more than profiledef.sh. A profile missing any of these builds
# for twenty minutes and then fails, or worse, produces an ISO that does not
# boot -- which is a slow and expensive way to learn about a missing file.
check_archiso_layout() {
    group "archiso profile completeness"
    local -a required=(
        iso/profiledef.sh
        iso/packages.x86_64
        iso/pacman.conf
        # The live medium's own initramfs. The `archiso` hook in here is what
        # finds the boot medium and pivots into the squashfs; without it the
        # image boots to an initramfs looking for a root that does not exist.
        iso/airootfs/etc/mkinitcpio.conf.d/archiso.conf
        iso/airootfs/etc/mkinitcpio.d/linux.preset
        iso/efiboot/loader/loader.conf
    )
    local f missing=0
    for f in "${required[@]}"; do
        if [[ -e $f ]]; then
            pass "$f"
        else
            fail "missing: $f"
            missing=$((missing + 1))
        fi
    done

    # The preset must actually define the entry mkarchiso looks for.
    if [[ -f iso/airootfs/etc/mkinitcpio.d/linux.preset ]]; then
        if grep -q "PRESETS=(.*archiso.*)" iso/airootfs/etc/mkinitcpio.d/linux.preset; then
            pass "linux.preset defines the 'archiso' preset"
        else
            fail "iso/airootfs/etc/mkinitcpio.d/linux.preset does not define PRESETS=('archiso')"
        fi
    fi
    if [[ -f iso/airootfs/etc/mkinitcpio.conf.d/archiso.conf ]]; then
        if grep -qE '^HOOKS=.*[( ]archiso[ )]' iso/airootfs/etc/mkinitcpio.conf.d/archiso.conf; then
            pass "the live initramfs includes the archiso hook"
        else
            fail "iso/airootfs/etc/mkinitcpio.conf.d/archiso.conf has no 'archiso' hook in HOOKS"
        fi
    fi

    # At least one package list entry must provide those hooks.
    if grep -qx 'mkinitcpio-archiso' iso/packages.x86_64 2>/dev/null; then
        pass "mkinitcpio-archiso is on the medium (it provides the archiso hook)"
    else
        fail "iso/packages.x86_64 is missing mkinitcpio-archiso"
    fi
}

check_rootfs_refs() {
    group "cross-references"

    # The initramfs build hook add_file's paths from the installed system. If one
    # is renamed, mkinitcpio fails at kernel-upgrade time -- the worst moment.
    local hook="rootfs/etc/initcpio/install/loom-rescue"
    local p rel bad=0
    while read -r p; do
        rel="rootfs$p"
        if [[ ! -e $rel ]]; then
            # Files from other packages (terminfo) are not ours to ship.
            case "$p" in /usr/share/terminfo/*) continue ;; esac
            fail "$hook add_file's $p, which Loom does not ship"
            bad=$((bad + 1))
        fi
    done < <(sed -n 's/^[[:space:]]*add_file[[:space:]]\+\([^[:space:]]*\).*/\1/p' "$hook")
    (( bad == 0 )) && pass "every add_file in the rescue hook exists"

    # systemd units that ExecStart something Loom ships.
    local unit cmd
    for unit in rootfs/etc/systemd/system/*.service; do
        [[ -f $unit ]] || continue
        while read -r cmd; do
            case "$cmd" in
                /usr/local/bin/*)
                    [[ -e "rootfs$cmd" ]] || fail "$(basename "$unit") runs $cmd, which is missing"
                    ;;
            esac
        done < <(sed -n 's/^ExecStart=-\?\([^ ]*\).*/\1/p' "$unit")
    done

    # pacman hooks.
    local h
    for h in rootfs/etc/pacman.d/hooks/*.hook; do
        [[ -f $h ]] || continue
        while read -r cmd; do
            case "$cmd" in
                /usr/local/bin/*)
                    [[ -e "rootfs$cmd" ]] || fail "$(basename "$h") runs $cmd, which is missing"
                    ;;
            esac
        done < <(sed -n 's/^Exec[[:space:]]*=[[:space:]]*\([^ ]*\).*/\1/p' "$h")
    done
    pass "units and pacman hooks point at scripts that exist"

    # Every boot entry must point at an image the presets actually build. A
    # rename on one side and not the other is a boot menu entry that drops you
    # into the firmware, discovered at the worst possible time.
    local -a uki_paths=()
    mapfile -t uki_paths < <(sed -n 's/^[a-z]*_uki="\(.*\)"$/\1/p' \
        rootfs/usr/share/loom/boot/linux.preset \
        rootfs/usr/share/loom/boot/loom-rescue.preset 2>/dev/null)
    local e efi_path n_entries=0 bad_entries=0
    for e in rootfs/usr/share/loom/boot/entries/*.conf; do
        [[ -f $e ]] || continue
        n_entries=$((n_entries + 1))
        efi_path=$(sed -n 's/^efi[[:space:]]*//p' "$e" | head -n1)
        if [[ -z $efi_path ]]; then
            fail "$(basename "$e") has no 'efi' line"
            bad_entries=$((bad_entries + 1))
        elif ! printf '%s\n' "${uki_paths[@]}" | grep -qx "/efi$efi_path"; then
            fail "$(basename "$e") points at $efi_path, which no preset builds"
            info "      presets build: ${uki_paths[*]}"
            bad_entries=$((bad_entries + 1))
        fi
    done
    if (( n_entries == 0 )); then
        fail "no boot entries in rootfs/usr/share/loom/boot/entries/"
    elif (( bad_entries == 0 )); then
        pass "$n_entries boot entries all point at images the presets build"
    fi

    # loomctl's help text and its dispatcher must not drift apart.
    local lc="rootfs/usr/local/bin/loomctl"
    local -a dispatched=() documented=()
    mapfile -t dispatched < <(sed -n '/^    case "\$cmd" in$/,/^    esac$/p' "$lc" \
        | sed -n 's/^        \([a-z|-]*\)).*/\1/p' | tr '|' '\n' | sed '/^$/d' | sort -u)
    mapfile -t documented < <(sed -n '/^usage()/,/^EOF$/p' "$lc" \
        | sed -n 's/^  \([a-z-]\+\)\([ [].*\)\?$/\1/p' | sort -u)
    local d miss=0
    for d in "${documented[@]}"; do
        printf '%s\n' "${dispatched[@]}" | grep -qx "$d" || { fail "loomctl help documents '$d', which is not dispatched"; miss=$((miss + 1)); }
    done
    (( miss == 0 )) && pass "loomctl: ${#documented[@]} documented commands all dispatch"
}

# --- 7. config sanity --------------------------------------------------------

check_configs() {
    group "config files"

    # The console palette must be exactly three lines of sixteen values, or
    # setvtrgb silently leaves the VGA defaults in place.
    local pal="rootfs/usr/share/loom/console/palette"
    if [[ -f $pal ]]; then
        local lines fields ln ok_pal=1
        lines=$(grep -c . "$pal")
        (( lines == 3 )) || { fail "$pal has $lines lines, expected 3 (r, g, b)"; ok_pal=0; }
        while read -r ln; do
            fields=$(tr ',' '\n' <<<"$ln" | grep -c .)
            (( fields == 16 )) || { fail "$pal: a line has $fields values, expected 16"; ok_pal=0; }
            if tr ',' '\n' <<<"$ln" | grep -qvE '^[0-9]{1,3}$'; then
                fail "$pal: a value is not an integer 0-255"; ok_pal=0
            fi
        done < <(grep . "$pal")
        (( ok_pal )) && pass "console palette is 3 x 16 valid values"
    else
        fail "$pal is missing"
    fi

    # Brace balance in the KDL files. Crude, but a missing brace in zellij's
    # config means a session that will not start, which is the one failure this
    # system is designed never to have.
    local k open close
    for k in rootfs/usr/share/loom/zellij/config.kdl rootfs/usr/share/loom/zellij/layouts/*.kdl; do
        [[ -f $k ]] || continue
        open=$(tr -cd '{' <"$k" | wc -c)
        close=$(tr -cd '}' <"$k" | wc -c)
        if (( open == close )); then
            pass "$(basename "$k"): braces balance ($open)"
        else
            fail "$(basename "$k"): $open '{' but $close '}'"
        fi
    done

    # loom.conf must be sourceable, since loomctl, loom-session and loom-gui all
    # source it.
    if [[ -f rootfs/etc/loom/loom.conf ]]; then
        if ( set -u; . rootfs/etc/loom/loom.conf ) 2>/dev/null; then
            pass "loom.conf sources cleanly"
        else
            fail "loom.conf is not sourceable by /bin/sh"
        fi
    fi

    # Every LOOM_* variable that a script reads should have a default in
    # loom.conf, otherwise a partial config produces surprising behaviour.
    local -a used=() declared=()
    mapfile -t used < <(grep -rhoE '\$\{?LOOM_[A-Z_]+' rootfs/usr/local/bin/ \
        | sed 's/[${]//g' | sort -u)
    mapfile -t declared < <(sed -n 's/^\(LOOM_[A-Z_]*\)=.*/\1/p' rootfs/etc/loom/loom.conf | sort -u)
    local v undeclared=0
    for v in "${used[@]}"; do
        case "$v" in LOOM_CONF|LOOM_LOG|LOOM_CONSOLE|LOOM_SESSION_STARTED) continue ;; esac
        printf '%s\n' "${declared[@]}" | grep -qx "$v" \
            || { warn "$v is read by a script but not set in loom.conf"; undeclared=$((undeclared + 1)); }
    done
    (( undeclared == 0 )) && pass "every LOOM_* variable used has a default in loom.conf"
}

# --- 8. docs -----------------------------------------------------------------

check_docs() {
    group "documentation"
    local -a expected=(README.md docs/design.md docs/install.md docs/updates.md
                       docs/secure-boot.md docs/tty.md docs/build.md docs/keys.md)
    local f
    for f in "${expected[@]}"; do
        [[ -f $f ]] && pass "$f" || fail "missing: $f"
    done

    # Links from the README to files in the repo.
    local link
    while read -r link; do
        [[ -e $link ]] || warn "README links to $link, which does not exist"
    done < <(grep -oE '\]\((docs/[^)#]+|scripts/[^)#]+|packages/[^)#]+)\)' README.md 2>/dev/null \
             | sed 's/^](//; s/)$//' | sort -u)
}

# --- main --------------------------------------------------------------------

printf '%sLoom static checks%s  %s\n' "$B" "$R" "$REPO"

check_crlf
check_syntax
check_shellcheck
check_exec_bits
check_package_lists
check_profiledef
check_archiso_layout
check_rootfs_refs
check_configs
check_docs

printf '\n'
if (( FAILURES == 0 )); then
    printf '%s  %d failure(s), %d warning(s)%s\n' "$GRN$B" "$FAILURES" "$WARNINGS" "$R"
    printf '  %sStatic checks only. Nothing here proves the ISO boots -- for that,\n' "$DIM"
    printf '  build it and run it in a UEFI VM. See docs/build.md.%s\n' "$R"
    exit 0
fi
printf '%s  %d failure(s), %d warning(s)%s\n' "$RED$B" "$FAILURES" "$WARNINGS" "$R"
exit 1
