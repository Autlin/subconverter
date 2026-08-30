import glob
import subprocess
import sys

MAIN_IMAGE_NAME="asdlokj1qpi23/subconverter"
TARGET_TAG="latest" if len(sys.argv) < 2 else sys.argv[1]

args=["docker manifest create {}:{}".format(MAIN_IMAGE_NAME, TARGET_TAG)]
for i in glob.glob("/tmp/images/*/*.txt"):
    with open(i, "r") as file:
        args += " --amend {}@{}".format(MAIN_IMAGE_NAME, file.readline().strip())
subprocess.run(args, check=True)
subprocess.run(["docker", "manifest", "push", "{}:{}".format(MAIN_IMAGE_NAME, TARGET_TAG)], check=True)
