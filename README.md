# sigstore-the-local-way

sigstore isn't scary.

This is a tutorial for setting up sigstore infrastructure locally, with a focus on learning what each component is and how it functions. 

This tutorial is based on [Sigstore the Hard Way](https://github.com/lukehinds/sigstore-the-hard-way) with the following changes:

* Cross-platform (Linux, OpenBSD, macOS)
* Local only - does not assume use of GCP or other Cloud providers
* Minimal use of root privileges

## Environment

This tutorial was initially developed on [https://openbsd.org/](OpenBSD), and is designed to work across a wide array of operating-systems and shells.

It does ocassionally refers to `doas`, a secure drop-in replacement for `sudo`. If it is not installed on your host, feel free to type `sudo` instead, install doas, or run `alias doas=sudo`.

As part of this tutorial, you will be starting a lot of daemons in the foreground. I highly recommend using a terminal environment that allows multiple sessions, such as tmux or screen.

## Installation of non-sigstore prerequisites

* OpenBSD: `doas pkg_add mariadb-server git redis go softhsm2 opensc`
* Debian: `sudo apt-get install -y mariadb-server git redis-server softhsm2 opensc`
* Fedora: `sudo dnf install madiadb-server git redis softhsm opensc'
* FreeBSD: `doas pkg install mariadb105-server git redis softhsm2 opensc`
* macOS: `sudo brew install mariadb redis softhsm opensc`

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

Start rekor:

```shell
$HOME/go/bin/rekor-server serve --rekor_server.address=0.0.0.0 --trillian_log_server.port=8091 --enable_retrieve_api=false 1
```

**TIP: If rekor shows the error 'Table 'test.Trees' doesn't exist', run the createdb.sh script again as it may have failed**

Test rekor:

```shell
cd $HOME/sigstore-local/src/rekor
$HOME/go/bin/rekor-cli upload --artifact tests/test_file.txt --public-key tests/test_public_key.key --signature tests/test_file.sig --rekor_server http://127.0.0.1:3000
```

If it works, the following will be output:

`Created entry at index 0, available at: http://127.0.0.1:3000/api/v1/log/entries/d2f305428d7c222d7b77f56453dd4b6e6851752ecacc78e5992779c8f9b61dd9`

Inspect the rekor record using:

```shell
curl -s http://127.0.0.1:3000/api/v1/log/entries/d2f305428d7c222d7b77f56453dd4b6e6851752ecacc78e5992779c8f9b61dd9 | jq
```

## Dex

Dex is a federated OpenID Connect Provider, which connects OpenID identities together from multiple providers to drive authentication for other apps.

```shell
cd $HOME/sigstore-local/src
git clone https://github.com/dexidp/dex.git
cd dex
gmake build
```

For this demonstration, we're going to use GitHub to authenticate requests, so create a test token at 
https://github.com/settings/applications/new

For the Homepage URL, use `http://localhost:5556/` and for the Authorization callback URL, use `http://localhost:5556/auth/callback`

Then place the following in $HOME/sigstore-local/dex-config.yaml:

```yaml
issuer: http://127.0.0.1

storage:
  type: sqlite3
  config:
    file: ./dex.db
web:
  http: 0.0.0.0:5556
frontend:
  issuer: sigstore
  theme: light

# Configuration for telemetry
telemetry:
  http: 0.0.0.0:5558

# Options for controlling the logger.
logger:
  level: "debug"
  format: "json"

# Default values shown below
oauth2:
  responseTypes: [ "code" ]
  skipApprovalScreen: false
  alwaysShowLoginScreen: true

staticClients:
  - id: sigstore
    public: true
    name: 'sigstore'
    redirectURIs:
    - 'http://localhost:5556/auth/callback'

connectors:
#- type: google
#  id: google-sigstore-test
#  name: Google
#  config:
#    clientID: $GOOGLE_CLIENT_ID
#    clientSecret: $GOOGLE_CLIENT_SECRET
#    redirectURI: https://${DOMAIN}/auth/callback

- type: github
  id: github-sigstore-test
  name: GitHub
  config:
     clientID: $GITHUB_CLIENT_ID
     clientSecret: $GITHUB_CLIENT_SECRET
     redirectURI: http://127.0.0.1:5556/dex/callback
```

Then run dex:

```shell
cd $HOME/sigstore-local
env GITHUB_CLIENT_ID=<id> GITHUB_CLIENT_SECRET=<secret> dex serve dex-config.yaml
```

## SoftHSM

SoftHSM is an implementation of a cryptographic store accessible through a PKCS #11 interface. You can use it to explore PKCS #11 without having a Hardware Security Module. By default, `$HOME/.config/softhsm2/tokens` is used as the store. This will create your first token:

`softhsm2-util --init-token --free --label fulcio`

Please set the pin to `2324` or at least memorize the PIN.

## OpenSC

Configure OpenSC:

* Linux: `export PKCS11_MOD=/usr/lib/softhsm/libsofthsm2.so`
* (FreeBSD|OpenBSD): `export PKCS11_MOD=/usr/local/lib/softhsm/libsofthsm2.so`

Use OpenSC to create a CA cert:

`pkcs11-tool --module=$PKCS11_MOD --login --login-type user --keypairgen --id 1 --label PKCS11CA --key-type EC:secp384`

**NOTE: Older versions of Fulcio used FulcioCA, but newer ones use PKCS11CA**

## Fulcio

On most platforms, install the latest Fulcio using:

```shell
go install github.com/sigstore/fulcio@latest
```

OpenBSD is temporarily an exception, as you'll need to override two of the dependencies due to out-of-date and incompatible components:

```
go mod edit -replace=github.com/ThalesIgnite/crypto11=github.com/tstromberg/crypto11@v1.2.6-0.20220126194112-d1d20b7b79b6 
go mod edit -replace=github.com/containers/ocicrypt=github.com/tstromberg/ocicrypt@v1.1.3-0.20220126200830-4f5e8d1378f0  
go mod tidy
go install .
```

Before we run Fulcio, we need to create a configuration file for the pkcs11 library:

```shell
cd $HOME/sigstore-local
mkdir config
echo "{ 'Path': '$PKCS11_MOD', 'TokenLabel': 'fulcio', 'Pin': '1234' }" > config/crypto11.conf
```

Now create a CA:

```shell
fulcio createca --org=acme --country=USA --locality=Anytown --province=AnyPlace --postal-code=ABCDEF --street-address=123 Main St --hsm-caroot-id 1 --out fulcio-root.pem
```

