"""Assemble a My Animals release; does not publish or expose private keys."""
import argparse, json, sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from miniapp_api import package_bytes, canonical, digest, validate_package

parser=argparse.ArgumentParser()
parser.add_argument('--version',type=int,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
package=json.loads(package_bytes());package['version']=args.version
raw=canonical(package).encode();validate_package(raw,'my-animals')
args.output.parent.mkdir(parents=True,exist_ok=True)
with args.output.open('xb') as target:target.write(raw)
print(f'{args.output}: {len(raw)} bytes; SHA-256 {digest(raw)}')
