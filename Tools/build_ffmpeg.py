"""Build the pinned, LGPL-only, standalone arm64 decoder used by binary releases."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '9.0.2'
ARCHIVE_NAME = f'ffmpeg-{VERSION}.tar.xz'
SOURCE_URL = f'https://ffmpeg.org/releases/{ARCHIVE_NAME}'
SOURCE_SHA256 = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
BUILD = ROOT / '.build/ffmpeg'
ARCHIVE = BUILD / ARCHIVE_NAME
SOURCE = BUILD / f'ffmpeg-{VERSION}'
OUTPUT = BUILD / 'bin/ffmpeg'
CONFIGURE = [
    '--prefix=/usr/local', '--cc=clang', '--arch=arm64', '--target-os=darwin',
    '--extra-cflags=-mmacosx-version-min=14.0', '--extra-ldflags=-mmacosx-version-min=14.0',
    '--disable-autodetect', '--disable-gpl', '--disable-nonfree', '--disable-doc',
    '--disable-debug', '--disable-shared', '--enable-static', '--disable-ffplay', '--disable-ffprobe',
    '--disable-everything', '--enable-ffmpeg',
    '--enable-protocol=file,pipe,fd,tcp,udp,rtp',
    '--enable-demuxer=concat,rtsp,sdp,h264,hevc,mjpeg,image2pipe',
    '--enable-parser=h264,hevc,mjpeg,mpeg4video,h263,vp8,vp9',
    '--enable-decoder=h264,hevc,mjpeg,mpeg4,h263,vp8,vp9,rawvideo',
    '--enable-encoder=mjpeg', '--enable-muxer=image2pipe',
    '--enable-filter=fps,scale,format,null,buffer,buffersink',
    '--enable-bsf=extract_extradata,h264_mp4toannexb,hevc_mp4toannexb',
    '--enable-videotoolbox', '--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox', '--disable-audiotoolbox',
]


def sha256(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def verify_license():
    text = subprocess.check_output([str(OUTPUT), '-L'], stderr=subprocess.STDOUT, text=True)
    if 'GNU Lesser General Public License' not in ' '.join(text.split()):
        raise SystemExit('Unexpected FFmpeg license; do not distribute this binary.')


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('The release decoder must be built on an Apple Silicon Mac.')
    BUILD.mkdir(parents=True, exist_ok=True)
    if not ARCHIVE.exists():
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', SOURCE_URL,
                        '--output', str(ARCHIVE)], check=True)
    if sha256(ARCHIVE) != SOURCE_SHA256:
        raise SystemExit('FFmpeg source checksum mismatch. Refusing to extract or build.')
    metadata_path = BUILD / 'build.json'
    if metadata_path.exists() and OUTPUT.exists():
        metadata = json.loads(metadata_path.read_text())
        if (metadata.get('source_sha256') == SOURCE_SHA256 and
                metadata.get('configure_arguments') == CONFIGURE and
                metadata.get('binary_sha256') == sha256(OUTPUT)):
            verify_license()
            print(f'Using verified cached FFmpeg {VERSION}: {OUTPUT}')
            return
    if SOURCE.exists():
        shutil.rmtree(SOURCE)
    with tarfile.open(ARCHIVE) as archive:
        archive.extractall(BUILD, filter='data')
    with (BUILD / 'configure.log').open('w') as log:
        subprocess.run(['./configure', *CONFIGURE], cwd=SOURCE, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    with (BUILD / 'make.log').open('w') as log:
        subprocess.run(['make', '-j', str(min(os.cpu_count() or 2, 6)), 'ffmpeg'], cwd=SOURCE,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    OUTPUT.parent.mkdir(exist_ok=True)
    shutil.copy2(SOURCE / 'ffmpeg', OUTPUT)
    OUTPUT.chmod(0o755)
    licenses = BUILD / 'licenses'
    licenses.mkdir(exist_ok=True)
    for name in ['COPYING.LGPLv2.1', 'LICENSE.md']:
        shutil.copy2(SOURCE / name, licenses / name)
    metadata = {'version': VERSION, 'source_url': SOURCE_URL, 'source_sha256': SOURCE_SHA256,
                'source_modified': False, 'configure_arguments': CONFIGURE,
                'binary_sha256': sha256(OUTPUT), 'license': 'LGPL-2.1-or-later'}
    verify_license()
    metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Built FFmpeg {VERSION}: {OUTPUT}')


if __name__ == '__main__':
    main()
