# spotifyripper
A bash script to record music from Spotify to **acc** or **ogg** files

## Dependencies
* [Spotify client](https://www.spotify.com/ec/download/linux/)
* fdkaac
* oggenc (usually in vorbis-tools)

## Installation
1. Clone this repository or download the file spotifyripper.sh
2. Make shure that the file is executable
```bash
chmod +x spotifyripper.sh
```
3. Disable the autoplay feature in the Spotify client. That is nessesary for the script to know when to stop recording
4. Play anything in spotify to create the pulseaudio sink for the first time
5. Execute the script ```./spotifyripper.sh```
6. Optinal: Install any missing dependencies. For exemple in debian/ubuntu ```apt install fdkaac vorbis-tools``` and repeat the step 5

**Recommended steps:**
1. Is better if you use a virtual machine or a dedicated computer to let Spotify run while you record. Some DE tend to switch to the null audio output al all applications
2. Disable the sound of the notifications on your DE
3. Do not use any application that could use sound while recording
4. Create a "bin" directory in your home directory and copy the script there to be able to execute the script in any path.
```bash
mkdir ~/bin
cp spotifyripper.sh ~/bin
```
5. To record first go to the destination directory and then execute the script
```bash
cd Music
spotifyripper.sh
```
## Options
You can give as first argument the destination directory. It defaults to the same directory that the script is called.

Copy the file spotifyripper.conf.example to spotifyripper.conf and keep it in the same directory as the script.

This are the options avaliable:

### Audio coding format

Posible values: "aac" or "ogg"

Example:
```bash
recordformat="ogg"
```

Default: "aac"

### AAC profile for fdkaac
Only aplies to the aac format. Ignored when ogg is used

Posible values: Any supported by [fdkaac](https://manpages.debian.org/stretch/fdkaac/fdkaac.1.en.html)

Example:
```bash
aac_profile="5"
```

Default: "29"

### Bit rate
Posible values: Any supported by [fdkaac](https://manpages.debian.org/buster/fdkaac/fdkaac.1.en.html) or [oggenc](https://manpages.debian.org/buster/vorbis-tools/oggenc.1.en.html)

Example:
```bash
bitrate="192"
```

Default: "48"

### File name scheme
Set the output file name / directory scheme

Posible values: 
* "normal" : Based on Artist / Album / Tittle
* "strict" : Based on Artist / Album / Tittle removing all special characters
* "strict-lc-nodir" : Creates no directory structure. It removes the special characters and converts to lower case the filename

Example:
```bash
filenamescheme="normal"
```

Default: "normal  "
