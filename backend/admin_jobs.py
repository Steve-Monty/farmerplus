"""Run scoped report schedules. Deploy as a supervised worker alongside the API."""
import argparse
import time
from app import app

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--once',action='store_true')
    args=parser.parse_args()
    while True:
        result=app.state.workspace.run_jobs()
        app.state.workspace.farmer_reporting.run_jobs()
        print(f"Reports completed: {result['completed']}; failed: {result['failed']}",flush=True)
        if args.once:break
        time.sleep(30)
