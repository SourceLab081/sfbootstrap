# Attempt to utilize more than one CPU thread for builds
util="$ANDROID_ROOT/rpm/dhd/helpers/util.sh"
if ! grep -q 'build -j' "$util"; then
    sed 's/build >>/build -j $(nproc) >>/' -i "$util"
fi

#word_list=("ofono-configs-binder" "bluez5-configs-mer" "jolla-devicelock-daemon-encpartition")
#regex=$(IFS='|'; echo "${word_list[*]}")
#if sfb_chroot sfossdk sh -c "sb2 -t $VENDOR-$DEVICE-$PORT_ARCH -m sdk-install -R zypper se -i" | egrep -q "$regex"; then
#sb2 -t $VENDOR-$DEVICE-$PORT_ARCH -m sdk-install -R zypper rm ofono-configs-binder bluez5-configs-mer jolla-devicelock-daemon-encpartition
#fi

