#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src
export PATH="$base/.clang/bin:$PATH"
if [[ $(command -v apt) ]]; then
    export OS=debian
elif [[ $(command -v dnf) ]]; then
    export OS=fedora
else
    export OS=archlinux
fi

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
    do_kernel
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets aarch64 arm x86_64
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0
    if [[ $OS == "archlinux" ]]; then
        # Refresh mirrorlist to avoid dead mirrors
        pacman -Syu --noconfirm

        pacman -S --noconfirm --needed \
            base-devel \
            bc \
            bison \
            ccache \
            clang \
            cmake \
            compiler-rt \
            cpio \
            curl \
            flex \
            git \
            github-cli \
            libarchive \
            libbsd \
            libcap \
            libedit \
            libelf \
            libffi \
            libtool \
            lld \
            llvm \
            make \
            ninja \
            openssl \
            patchelf \
            python-pyelftools \
            python-setuptools \
            python3 \
            uboot-tools
    elif [[ $OS == "fedora" ]]; then
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
    TomTal=$TomTal+1

    "$base"/build-llvm.py \
        --install-folder "$install" \
        --vendor-string "$LLVM_VENDOR_STRING" \
        --targets AArch64 ARM X86 \
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
    for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
        strip -s "${f::-1}"
    done

    # Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
    for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
        # Remove last character from file output (':')
        bin="${bin::-1}"

        echo "$bin"
        patchelf --set-rpath install/lib "$bin"
    done

    # Get git commit hash
    git_hash=$(git -C "$base"/llvm-project rev-parse --short HEAD)
    clang_version=$("$base"/install/bin/clang --version | head -n 1 | awk '{print $4}')
    major_version=$(echo "$clang_version" | cut -d. -f1)

    if [[ $OS == "archlinux" ]]; then
        file_name="$LLVM_VENDOR_STRING"-clang_"$clang_version"-archlinux-"$git_hash".tar.xz
    elif [[ $OS == "debian" ]]; then
        file_name="$LLVM_VENDOR_STRING"-clang_"$clang_version"-bookworm-"$git_hash".tar.xz
    elif [[ $OS == "fedora" ]]; then
        # Create RPM structure
        rpmbuild_dir="$base/rpmbuild"
        mkdir -p "$rpmbuild_dir"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

        # Create tarball for RPM source
        src_tar="clang-$clang_version.tar.gz"
        tar -czf "$rpmbuild_dir/SOURCES/$src_tar" -C "$install" .

        # Create SPEC file
        cat <<EOF >"$rpmbuild_dir/SPECS/clang.spec"
Name:           clang-$LLVM_VENDOR_STRING
Version:        $major_version
Release:        $git_hash%{?dist}
Summary:        Custom LLVM/Clang build
License:        Apache-2.0
Source0:        $src_tar
BuildArch:      x86_64
AutoReqProv:    no
Provides:       clang llvm lld polly openmp compiler-rt binutils

%description
Custom LLVM/Clang build by $LLVM_VENDOR_STRING

%prep
%setup -c

%install
mkdir -p %{buildroot}/usr
cp -r * %{buildroot}/usr/

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
        mv "$rpmbuild_dir"/RPMS/x86_64/*.rpm "$base"/dist/

        # Upload RPMs
        for rpm in "$base"/dist/*.rpm; do
            curl -X POST -F "file=@$rpm" https://temp.wulan17.dev/api/v1/upload
        done
        return
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
        find "$base"/dist/ -maxdepth 1 -name "*.rpm" -print0 | while IFS= read -r -d '' f; do
            file_name="$f"
            # Just take the first one or we can stick to one var.
            # Ideally we should upload all, but let's stick to the structure.
            # Assuming one RPM for now or we will just use the last found for ASSET assignment variable (logic below only supports one asset)
            # To support multiple, we'd need to loop the upload command.
            break
        done
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
