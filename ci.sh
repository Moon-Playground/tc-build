#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src
export PATH="$base/.clang/bin:$PATH"

# OS Detection
if [[ $(command -v dnf) ]]; then
    export OS=fedora
else
    export OS=debian
fi

# Architecture Detection
ARCH=$(uname -m)
export ARCH

set -eu

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | kernel | llvm | compress | release) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
    [[ $ARCH == "x86_64" ]] && do_kernel
}

function do_binutils() {
    local targets=("aarch64" "arm")
    [[ $ARCH == "x86_64" ]] && targets+=("x86_64")

    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets "${targets[@]}"
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0
    if [[ $OS == "fedora" ]]; then
        dnf install -y \
            bc \
            bison \
            ccache \
            clang \
            cmake \
            compiler-rt \
            cpio \
            curl \
            flex \
            gcc-c++ \
            git \
            gh \
            libbsd-devel \
            libcap-devel \
            libedit-devel \
            libffi-devel \
            libtool \
            lld \
            llvm-devel \
            make \
            ncurses-compat-libs \
            ninja-build \
            openssl-devel \
            patchelf \
            perl-Digest-SHA \
            python3-pyelftools \
            python3-setuptools \
            rpm-build \
            rpmdevtools \
            uboot-tools \
            wget \
            xz \
            zlib-devel
    else
        # Refresh mirrorlist to avoid dead mirrors
        apt update -y

        apt install -y --no-install-recommends \
            bc \
            bison \
            ca-certificates \
            clang \
            cmake \
            curl \
            file \
            flex \
            g++ \
            gcc \
            gh \
            git \
            libbsd-dev \
            libcap-dev \
            libedit-dev \
            libelf-dev \
            libffi-dev \
            libssl-dev \
            libstdc++-12-dev \
            lld \
            make \
            ninja-build \
            patchelf \
            python3 \
            texinfo \
            wget \
            xz-utils \
            zlib1g-dev
    fi
}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux=$src/$branch

    if [[ -d $linux ]]; then
        git -C "$linux" fetch --depth=1 origin $branch
        git -C "$linux" reset --hard FETCH_HEAD
    else
        git clone \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$linux"
    fi

    cat <<EOF | env PYTHONPATH="$base"/tc_build python3 -
from pathlib import Path

from kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['X86']}
builder.toolchain_prefix = Path('$install')

builder.build()
EOF
}

function do_llvm() {
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)
    TomTal=$(nproc)
    TomTal=$((TomTal + 1))

    local targets=("AArch64" "ARM")
    [[ $ARCH == "x86_64" ]] && targets+=("X86")

    "$base"/build-llvm.py \
        --install-folder "$install" \
        --vendor-string "$LLVM_VENDOR_STRING" \
        --targets "${targets[@]}" \
        --defines "LLVM_PARALLEL_COMPILE_JOBS=$TomTal LLVM_PARALLEL_LINK_JOBS=$TomTal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' LLVM_USE_LINKER=lld LLVM_ENABLE_LLD=ON" \
        --projects clang compiler-rt lld polly openmp \
        --no-ccache \
        --quiet-cmake \
        --llvm-folder "$base"/llvm-project \
        --lto thin \
        "${extra_args[@]}"
}

function do_compress() {

    # Remove unnecessary files
    rm -fr "$install"/include
    rm -f "$install"/lib/*.a "$install"/lib/*.la

    # Strip remaining binaries
    # Avoid strip failing on non-ELFs
    find "$install" -type f -exec file {} \; | grep 'not stripped' | cut -d: -f1 | while read -r f; do
        strip -s "$f" || true
    done

    if [[ $OS != "fedora" ]]; then
        # Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
        find "$install" -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | cut -d: -f1 | while read -r bin; do
            echo "$bin"
            patchelf --set-rpath "$install/lib" "$bin"
        done
    fi

    # Get git commit hash
    git_hash=$(git -C "$base"/llvm-project rev-parse --short HEAD)
    clang_version=$("$base"/install/bin/clang --version | head -n 1 | awk '{print $4}')
    major_version=$(echo "$clang_version" | cut -d. -f1)

    if [[ $OS == "fedora" ]]; then
        # Create RPM structure
        rpmbuild_dir="$base/rpmbuild"
        mkdir -p "$rpmbuild_dir"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

        # Create tarball for RPM source
        src_tar="clang-$clang_version.tar.gz"
        tar -czf "$rpmbuild_dir/SOURCES/$src_tar" -C "$install" .

        # Create SPEC file
        cat <<EOF >"$rpmbuild_dir/SPECS/clang.spec"
# Disable the build-id and debuginfo generation that is causing the crash
%define _missing_build_ids_terminate_build 0
%define debug_package %{nil}
%global __brp_ldconfig /usr/bin/true
%global __brp_strip /usr/bin/true
%global __brp_mangled_shebangs /usr/bin/true

Name:           clang-$LLVM_VENDOR_STRING
Version:        $major_version
Release:        $git_hash%{?dist}
Summary:        Custom LLVM/Clang build
License:        Apache-2.0
Source0:        $src_tar
BuildArch:      $ARCH
AutoReqProv:    no
Provides:       clang llvm lld polly openmp compiler-rt binutils

%description
Custom LLVM/Clang build by $LLVM_VENDOR_STRING

%prep
%setup -c

%install
mkdir -p %{buildroot}/usr
cp -r * %{buildroot}/usr/

# Fix ambiguous python shebangs
find %{buildroot}/usr/share/opt-viewer/ -name "*.py" -exec sed -i '1s|#!.*python|#!/usr/bin/python3|' {} +

# Fix executable bit warnings
chmod -x %{buildroot}/usr/share/opt-viewer/style.css
chmod -x %{buildroot}/usr/share/opt-viewer/optpmap.py

%files
/usr/*

%changelog
* $(date "+%a %b %d %Y") $LLVM_VENDOR_STRING - $major_version-$git_hash
- Automated build
EOF

        # Build RPM
        rpmbuild -bb "$rpmbuild_dir/SPECS/clang.spec" --define "_topdir $rpmbuild_dir"

        # Move RPM to dist
        mkdir -p "$base"/dist
        mv "$rpmbuild_dir"/RPMS/"$ARCH"/*.rpm "$base"/dist/

        # Upload RPMs
        for rpm in "$base"/dist/*.rpm; do
            curl -X POST -F "file=@$rpm" https://temp.wulan17.dev/api/v1/upload
        done
        return
    else
        # Detect distro codename (e.g., bookworm, jammy)
        if [[ -f /etc/os-release ]]; then
            distro_name=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '\"')
            # If VERSION_CODENAME is empty (common on Ubuntu), try UBUNTU_CODENAME or ID
            [[ -z $distro_name ]] && distro_name=$(grep "^UBUNTU_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '\"')
            [[ -z $distro_name ]] && distro_name=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '\"')
        fi
        # Default to "linux" if detection failed
        distro_name=${distro_name:-linux}
        file_name="$LLVM_VENDOR_STRING"-clang_"$clang_version"-"$distro_name"-"$ARCH"-"$git_hash".tar.xz
    fi

    # Compress the install folder to save space
    mkdir -p "$base"/dist
    cd "$install"
    tar -cJf "$base"/dist/"$file_name" -- *
    curl -X POST -F "file=@$base/dist/$file_name" https://temp.wulan17.dev/api/v1/upload
}

function do_release() {
    # Upload to GitHub Releases using GitHub CLI
    file_name=""
    if [[ $OS == "fedora" ]]; then
        # Find RPM files
        while IFS= read -r -d '' f; do
            file_name="$f"
            break
        done < <(find "$base"/dist/ -maxdepth 1 -name "*.rpm" -print0)
    else
        while IFS= read -r -d '' f; do
            file_name="$f"
            break
        done < <(find "$base"/dist/ -maxdepth 1 -name "${LLVM_VENDOR_STRING}-clang_*.tar.xz" -print0)
    fi

    if [[ -z $file_name ]]; then
        echo "No file found to upload."
        exit 1
    fi

    clang_version=$("$base"/install/bin/clang --version | head -n 1 | awk '{print $4}')
    git_hash=$(git -C "$base"/llvm-project rev-parse --short HEAD)

    TAG="$clang_version-$git_hash"
    ASSET="$file_name"
    REPO="$GITHUB_REPOSITORY"
    TITLE="$LLVM_VENDOR_STRING Clang $clang_version ($git_hash)"
    NOTES="$LLVM_VENDOR_STRING Clang $clang_version ($git_hash)"

    # Check if release exists
    if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
        echo "Release $TAG exists, uploading asset..."
        gh release upload "$TAG" "$ASSET" --repo "$REPO" --clobber
    else
        echo "Release $TAG does not exist, creating release and uploading asset..."
        gh release create "$TAG" "$ASSET" \
            --title "$TITLE" \
            --notes "$NOTES" \
            --target "$GITHUB_REF_NAME" \
            --repo "$REPO"
    fi
    echo "Released successfully."
}

parse_parameters "$@"
do_"${action:=all}"
