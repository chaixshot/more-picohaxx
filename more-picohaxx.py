def generate_unlock(serial: int):
	key = "0XD9J6FB3ATQIHNM46XYZZZOPQRSTUVWXYZ"

	val = serial & 0xF7F3F37F

	if val == 0:
		encoded_serial = key[0]
	else:
		encoded_chars = []
		while val > 0:
			encoded_chars.append(key[val & 0xF])
			val >>= 4
		encoded_serial = "".join(reversed(encoded_chars))

	return f"fastboot oem pico{encoded_serial} unlock"

def pico_unlock(serial: int):
	print(f"ser: {hex(serial)} {serial} \n{generate_unlock(serial)}")

# put /sys/devices/soc0/serial_number here (decimal)
pico_unlock(1234567)

"""

** Unlocking your Pico 3/4 bootloader **

	How is this possible?
	=============================
	Normally unlocking the bootloader on Pico3 and 4 is gated and requires you to flash an "unlocktoken"
	It's basically your chip serial plus some options encrypted with picos secret rsa key.
	The whole mechanism is as simple as it is effective and the crypto is sound.
	However Pico was so nice and (as of this writing still) provides a complete engineering firmware that includes a signed firehose
	right on their download server. With this you can downgrade your abl to a very early Pico 3 version, that only uses a simple serial
	number, derived from the unique qchip_id to gate the unlock commands! This lets you issue "critical_unlock", but it usually wont stick on the first try.
	I'm not sure if this is just a bug in the abl, but if your device returns to the locked state after reboot, just issue the commands again. At some point it 
	is known to work.
	Now the unlock bits are actually written to the protected RPMB storage, and even the original Pico 4 abl will honor them without any token. 
	You will loose the unlocked fastboot access if you go back to the original abl though. As a nice side effect you will also get selinux 
	permissive at boot, so i just stayed with the Pico 3 abl.

	Note: I only tried this on my Pico 4, at this point i just assume it works the same on Pico 3.

*WARNING*
	Do not attempt this unless you're familiar with adb, edl and fastboot. 
	Also: unlocking the bootloader will wipe your data partition. Be sure to backup anything you like to keep.


[1]
	grab /sys/devices/soc0/serial_number via adb and generate your unlock code.

[2]
	acquire the abl from the early Pico3 firmware.
	there's no need to download the whole archive, just go:
	$ pip install remotezip
	$ remotezip -d . https://zstatic.us-pui.picovr.com/syspackage_web/update_PicoNeo3_4.6.3-202203312043-RELEASE-user-neo3-b678-55ecdee5d1_SEKSA-B678.zip "firmware-update/abl.elf"

[3]
	get your hands onto the leaked Pico firehose:

	$ remotezip -d . https://static.us-pui.picovr.com/SEKSA-pico_rls_neo3-mol-tob-pui-4.8.0-20220622-falconcv3-user-20221017-225305-32g-b1981.zip "SEKSA-pico_rls_neo3-mol-tob-pui-4.8.0-20220622-falconcv3-user-20221017-225305-32g-b1981/prog_firehose_ddr.elf"

	in case they no longer host it, it should be easy enough to find on the internet.

[4]
	boot into edl then flash abl and the devinfo provided in this repo. backup your old abl!
	i used https://github.com/bkerler/edl

[5]
	once you flash the abl, the device will no longer boot (at least on Pico 4). 
	make sure it's in fastboot mode then issue:
		"fastboot oem picoXXXXXXXX unlock"
		"fastboot oem setenforce 0"
		"fastboot flashing unlock"
		"fastboot flashing unlock_critical"

	now "fastboot oem device-info" should show:
		(bootloader) Verity mode: true
		(bootloader) Device unlocked: true
		(bootloader) Device critical unlocked: true
[6]
	fastboot reboot bootloader. you should be back at the fastboot menu and it should show "unlocked"
    If it doesn't, repeat the same process again. Unlocking may require a few bootloader reboots and repeating the commands before it takes effect.

[7]
	now try a normal boot and it will ask you to factory reset. once you do that, your bootloader will be unlocked
	and you'll be able to boot normally again.

[8]
    !!! It is highly recommended to flash back the original abl from your firmware, especially on Pico 4 !!!
	
[9]
	enjoy!
	Big thx to Fallen Angel for his fearless testing.
	[typlo]
"""
