# sigstore-the-local-way

sigstore isn't scary.

This is a tutorial for setting up sigstore infrastructure locally, with a focus on learning what each component is and how it functions. 

This tutorial is based on [https://github.com/lukehinds/sigstore-the-hard-way](Sigstore the Hard Way), but avoids using external infrastructure (GCP, LetsEncrypt), etc. As the intention is not a production-ready environment, we will store most data within the users home directory.

## Environment

This tutorial was developed on [https://openbsd.org/](OpenBSD), but it is intended to be cross-platform and executable using shells other than bash. 

This tutorial uses ocassionally refers to `doas`, a secure drop-in replacement for `sudo`. If it is not installed on your host, feel free to type `sudo` instead, install doas, or run `alias doas=sudo`.

As part of this tutorial, you will be starting a lot of daemons in the foreground. I highly recommend using a terminal environment that allows multiple sessions, such as tmux or screen.

## Installation of non-sigstore prerequisites

* OpenBSD: `doas pkg_add mariadb-server git redis go softhsm2`
* Debian: `sudo apt-get install -y mariadb-server git redis-server softhsm2`
* Fedora: `sudo dnf install madiadb-server git redis softhsm'
* FreeBSD: `sudo pkg install mariadb105-server git redis softhsm2`
* macOS: `sudo brew install mariadb redis softhsm`

Verify that the Go version in your path is v1.16 or higher:

`go version`

If not, uninstall Go and install the latest from https://go.dev/dl/

## MariaDB

While Sigstore can use multiple database backends, this tutorial uses MariaDB. Assuming you've installed the pre-requisites though, we can run the following to start the database up locally in a locked-down fashion:

* OpenBSD: `doas mysql_install_db && doas rcctl start mysqld && doas mysql_secure_installation`
* Debian: `sudo mysql_secure_installation`
* Fedora: TODO
* FreeBSD: TODO
* macOS: `sudo brew services start mariadb && sudo mysql_secure_installation`

## Trillian

Trillian is an append-only log for storing records. To install it:

```
go install github.com/google/trillian/cmd/trillian_log_server@latest 
go install github.com/google/trillian/cmd/trillian_log_signer@latest 
```

Trillian has two daemons, first is the log server:

`trillian_log_server -http_endpoint=localhost:8090 -rpc_endpoint=localhost:8091 --logtostderr`

Then is the log signer:

`trillian_log_signer --logtostderr --force_master --http_endpoint=localhost:8190 -rpc_endpoint=localhost:8191  --batch_size=1000 --sequencer_guard_window=0`

## Rekor

Rekor is sigstores signature transparency log. Install it from source:

```shell
mkdir -p $HOME/sigstore-local/src
cd $HOME/sigstore-local/src
git clone https://github.com/sigstore/rekor.git
cd rekor
pushd cmd/rekor-cli && go install && popd
pushd cmd/rekor-server && go install && popd
```

Drop and create a 'test' database with a username of `test` and a password of `zaphod':

```shell
cd scripts
doas bash createdb.sh
```

