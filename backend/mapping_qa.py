"""Isolated local QA host. No production service or account is modified."""
from pathlib import Path
from app import create_app
app=create_app(data_dir=Path(__file__).resolve().parent/'data'/'mapping-qa',testing=True)

