# Install a specific Python version (Ubuntu/Debian)

This guide includes two common approaches.

## Approach 1: `deadsnakes` PPA (Ubuntu)

```bash
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update

sudo apt install -y python3.9
python3.9 --version
```

## Approach 2: Build from source (portable)

```bash
sudo apt update
sudo apt install -y build-essential wget libssl-dev zlib1g-dev \
  libncurses5-dev libncursesw5-dev libreadline-dev libsqlite3-dev \
  libgdbm-dev libdb5.3-dev libbz2-dev libexpat1-dev liblzma-dev tk-dev

wget https://www.python.org/ftp/python/3.9.0/Python-3.9.0.tgz
tar xzf Python-3.9.0.tgz
cd Python-3.9.0

./configure
make
sudo make install
```

Install pip and packages:

```bash
sudo apt install -y python3-pip
python3 -m pip install pytest
```
