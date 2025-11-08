# sfbootstrap env for xiaomi-fog
VENDOR=xiaomi
VENDOR_PRETTY="Xiaomi"
DEVICE=fog
DEVICE_PRETTY="Redmi 10C"
#HABUILD_DEVICE=$DEVICE
#HOOKS_DEVICE=$SFB_DEVICE
PORT_ARCH=aarch64
SOC=qcom
PORT_TYPE=hybris
HYBRIS_VER=18.1
ANDROID_MAJOR_VERSION=11
#REPO_INIT_URL="https://github.com/SailfishOS-miatoll/android.git"
REPO_INIT_URL="https://github.com/SailfishOS-msmnile/manifest.git"
REPO_LOCAL_MANIFESTS_URL="https://github.com/SourceLab081/local_manifests"
#HAL_MAKE_TARGETS=(hybris-hal droidmedia bzip2 libbiometry_fp_api)
HAL_MAKE_TARGETS=(hybris-hal droidmedia)
HAL_ENV_EXTRA=""
RELEASE=5.0.0.67
TOOLING_RELEASE=5.0.0.62
SDK_RELEASE=latest
REPOS=(
     'https://github.com/SourceLab081/hybris-patches.git' hybris-patches "hybris-18.1" 1
 #   'https://github.com/mer-hybris/libhybris.git' hybris/mw/libhybris "master" 1
)
#REPOS=(
 #   'https://gitlab.com/TheXPerienceProject/yuki_clang.git' prebuilts/yuki-clang "18.0.0" 1
 #   'https://github.com/mer-hybris/libhybris.git' hybris/mw/libhybris "master" 1
#)
#LINKS=()
export VENDOR DEVICE PORT_ARCH RELEASE
