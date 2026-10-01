"""Install the pinned official Linux map extractor during the test image build."""
import hashlib
import io
import platform
import tarfile
import urllib.request
from pathlib import Path


def install():
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise RuntimeError('This pinned map extractor requires Linux x86_64.')
    url = 'https://github.com/protomaps/go-pmtiles/releases/download/v1.31.2/go-pmtiles_1.31.2_Linux_x86_64.tar.gz'
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read(100 * 1024 * 1024)
    if hashlib.sha256(archive).hexdigest() != '3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f':
        raise RuntimeError('Map extractor release checksum did not match.')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        member = next(m for m in tar.getmembers() if m.isfile() and Path(m.name).name == 'pmtiles')
        binary = tar.extractfile(member).read()
    path = Path('/usr/local/bin/pmtiles')
    path.write_bytes(binary)
    path.chmod(0o755)


if __name__ == '__main__':
    install()
