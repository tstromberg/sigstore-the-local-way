# sigstore-the-local-way

**NOTE: This tutorial is a work-in-progress: Please do not expect it to work yet. PR's welcome**

sigstore isn't scary.

This is a tutorial for setting up sigstore infrastructure locally, with a focus on learning what each component is and how it functions. 

This tutorial is based on [Sigstore the Hard Way](https://github.com/lukehinds/sigstore-the-hard-way) with the following changes:

* Simpler: Skips or combines unneccessary steps when possible, such as omitting DNS configuration
* Cross-platform (Linux, OpenBSD, macOS, etc)
* Local only - does not use of GCP or other Cloud providers
* Minimal use of root privileges

## Environment

This tutorial was initially developed on [https://openbsd.org/](OpenBSD), and is designed to work across a wide array of operating-systems and shells.

It does ocassionally refers to `doas`, a secure drop-in replacement for `sudo`. If it is not installed on your host, feel free to type `sudo` instead, install doas, or run `alias doas=sudo`.

As part of this tutorial, you will be starting a lot of daemons in the foreground. I highly recommend using a terminal environment that allows multiple sessions, such as tmux or screen.

## Installation of non-sigstore prerequisites

* Debian: `sudo apt-get install -y mariadb-server git redis-server softhsm2 opensc`
* Fedora: `sudo dnf install madiadb-server git redis go softhsm opensc`
* FreeBSD: `doas pkg install mariadb105-server git redis softhsm2 opensc`
* macOS: `brew install mariadb redis go softhsm opensc`
* OpenBSD: `doas pkg_add mariadb-server git redis go softhsm2 opensc`
* NetBSD: `doas pkgin install mariadb-server git redis go softhsm2 opensc`

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
go install github.com/google/trillian/cmd/createtree@latest
```

Trillian has two daemons, first is the log server:

`$HOME/go/bin/trillian_log_server -http_endpoint=localhost:8090 -rpc_endpoint=localhost:8091 --logtostderr`

Then is the log signer:

`$HOME/go/bin/trillian_log_signer --logtostderr --force_master --http_endpoint=localhost:8190 -rpc_endpoint=localhost:8191`

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
bash createdb.sh
```

(If MySQL asks for a root password, you can try running the script as root)

Start rekor:

```shell
$HOME/go/bin/rekor-server serve --trillian_log_server.port=8091 --enable_retrieve_api=false
```

**TIP: If rekor shows the error 'Table 'test.Trees' doesn't exist', run the createdb.sh script again as it may have failed**

Test rekor:

```shell
cd $HOME/sigstore-local/src/rekor
$HOME/go/bin/rekor-cli upload --artifact tests/test_file.txt --public-key tests/test_public_key.key --signature tests/test_file.sig --rekor_server http://localhost:3000
```

If it works, the following will be output:

`Created entry at index 0, available at: http://127.0.0.1:3000/api/v1/log/entries/d2f305428d7c222d7b77f56453dd4b6e6851752ecacc78e5992779c8f9b61dd9`

Inspect the rekor record using:

```shell
curl -s http://127.0.0.1:3000/api/v1/log/entries/d2f305428d7c222d7b77f56453dd4b6e6851752ecacc78e5992779c8f9b61dd9 | jq
```

## Dex

Dex is a federated OpenID Connect Provider, which connects OpenID identities together from multiple providers to drive authentication for other apps. Dex will serve as your OIDC issuer. Unfortunately, Dex doesn't support `go install` so you need to build it manually:

```shell
cd $HOME/sigstore-local/src
git clone https://github.com/dexidp/dex.git
cd dex
gmake build || make build
cp bin/dex $HOME/go/bin
```

For this demonstration, we're going to use GitHub to authenticate requests, so create a test token at 
https://github.com/settings/applications/new

For the Homepage URL, use `http://localhost:5556/` and for the Authorization callback URL, use `http://localhost:5556/auth/callback`

Run this to populate the Dex configuration:

```yaml
GITHUB_CLIENT_ID=<your ID> GITHUB_CLIENT_SECRET=<your secret> printf "\
issuer: http://localhost:5556

storage:
  type: sqlite3
  config:
    file: ./dex.db
web:
  http: 127.0.0.1:5556
frontend:
  issuer: sigstore
  theme: light

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

connectors:
- type: github
  id: github-sigstore-test
  name: GitHub
  config:
     clientID: $GITHUB_CLIENT_ID
     clientSecret: $GITHUB_CLIENT_SECRET
     redirectURI: http://localhost:5556/callback
" > $HOME/sigstore-local/dex-config.yaml
```

Start dex:

```shell
$HOME/go/bin/dex serve $HOME/sigstore-local/dex-config.yaml
```

## SoftHSM

SoftHSM is an implementation of a cryptographic store accessible through a PKCS #11 interface. You can use it to explore PKCS #11 without having a Hardware Security Module. By default, `$HOME/.config/softhsm2/tokens` is used as the store. This will create your first token:

`softhsm2-util --init-token --slot 0 --label fulcio`

Please set the pin to `2324` or at least memorize the PIN.

## OpenSC

Configure OpenSC:

* (FreeBSD|OpenBSD|NetBSD): `export PKCS11_MOD=/usr/local/lib/softhsm/libsofthsm2.so`
* Linux: `export PKCS11_MOD=/usr/lib/softhsm/libsofthsm2.so`
* macOS: `export PKCS11_MOD=$(brew --prefix softhsm)/lib/softhsm/libsofthsm2.so`

Use OpenSC to create a CA cert:

`pkcs11-tool --module=$PKCS11_MOD --login --login-type user --keypairgen --id 1 --label PKCS11CA --key-type EC:secp384r1`

**NOTE: Older versions of Fulcio used a key label of 'FulcioCA'**

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
echo "{ \"Path\": \"$PKCS11_MOD\", \"TokenLabel\": \"fulcio\", \"Pin\": \"2324\" }" > config/crypto11.conf
```
Ccreate a CA:

```shell
fulcio createca --org=acme --country=USA --locality=Anytown --province=AnyPlace --postal-code=ABCDEF --street-address=123 Main St --hsm-caroot-id 1 --out fulcio-root.pem
```

Older versions of fulcio may say: `finding slot for private key: FulcioCA` followed by `'invalid memory address or nil pointer dereference'`. If so, run this before retrying:

`pkcs11-tool --module=$PKCS11_MOD --login --login-type user --keypairgen --id 1 --label PKCS11CA --key-type EC:secp384r1`

Populate the Fulcio configuration file:


```shell
printf '
{
  "OIDCIssuers": {
    "https://accounts.google.com": {
      "IssuerURL": "https://accounts.google.com",
      "ClientID": "sigstore",
      "Type": "email"
    },
    "http://127.0.0.1:5556": {
      "IssuerURL": "http://127.0.0.1:5556",
      "ClientID": "sigstore",
      "Type": "email"
    }
  }
}
' > $HOME/sigstore-local/config/fulcio.json
```

Start Fulcio:

`$HOME/go/bin/fulcio serve --config-path=config/fulcio.json --ca=pkcs11ca --hsm-caroot-id=1 --ct-log-url=http://localhost:6105/sigstore --host=127.0.0.1 --port=5000`

**NOTE: Older versions of fulcio should use --ca=fulcioca**

You should see a message similar to:

`2022-01-27T16:35:11.359-0800	INFO	app/serve.go:173	0.0.0.0:5000`

If you do, then grab yourself some ice cream and party! 🎉 Congratulations on making it this far.


## Certificate Transparency Server

`go install github.com/google/certificate-transparency-go/trillian/ctfe/ct_server@latest`

Next we need to setup a private key. Remember the passphrase you give in the second part as you will need it.

```
cd $HOME/sigstore-local
openssl ecparam -genkey -name prime256v1 -noout -out unenc.key
openssl ec -in unenc.key -out privkey.pem -des
rm unenc.key
```

Next, we'll talk to the trillian_log_server we just stood up to grab a log ID:

`$HOME/go/bin/createtree --admin_server localhost:8091`

This command will output a long log ID number, which you will momentarily.

Populate `$HOME/sigstore-local/ct.cfg`, replacing <Log ID number> and <passphrase>:

```
LOG_ID=<log id> PASS=<password> printf "\
config {
  log_id: $LOG_ID
  prefix: \"sigstore\"
  roots_pem_file: \"./fulcio-root.pem\"
  private_key: {
    [type.googleapis.com/keyspb.PEMKeyFile] {
       path: \"./privkey.pem\"
       password: \"$PASS\"
    }
  }
}
" > $HOME/sigstore-local/ct.cfg
```

Next, start the certificate transparency server:
  
`$HOME/go/bin/ct_server -logtostderr -log_config $HOME/sigstore-local/ct.cfg -log_rpc_server localhost:8091 -http_endpoint 0.0.0.0:6105`
  
If it's successful, the output will look like:
  
```
I0128 11:42:16.401794   65425 main.go:121] **** CT HTTP Server Starting ****
I0128 11:42:16.401907   65425 main.go:174] Using regular DNS resolver
I0128 11:42:16.401915   65425 main.go:181] Dialling backend: name:"default" backend_spec:"localhost:8091"
I0128 11:42:16.510549   65425 main.go:306] Enabling quota for requesting IP
I0128 11:42:16.510562   65425 main.go:316] Enabling quota for intermediate certificates
I0128 11:42:16.511090   65425 instance.go:85] Start internal get-sth operations on sigstore (8494167753837750461)
```
  
If not, chances are that you typo'd the log_id or password. :) 
  
## Registry
  
While we could feasibly use any container registry, themeatically, we're going to run our own local registry:

`go install github.com/google/go-containerregistry/cmd/registry@latest`
  
And run our local registry on port 1338 (no flags required):
  
`$HOME/go/bin/registry`
  
Then we can push a test image to the registry using `ko`:
  
```
go install github.com/google/ko@latest
cd $HOME/sigstore-local/src/rekor/cmd
KO_DOCKER_REPO=127.0.0.1:1338/local ko publish ./rekor-cli
```
  
## Sign things using cosign!

**NOTE: This step is still under development**
  
Install the latest release:
  
`go install github.com/sigstore/cosign/cmd/cosign@latest`
  
Sign the container you published:

`COSIGN_EXPERIMENTAL=1 cosign sign --oidc-issuer "http://127.0.0.1:5556/auth" --fulcio-url "http://127.0.0.1:5000" --rekor-url "http://127.0.0.1:3000" 127.0.0.1:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest`

Sign an arbitrary tarball:
  
TBD
  
Verify signatures
  
TBD
  
