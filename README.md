# sigstore-the-local-way (UNDER DEVELOPMENT)

This is a tutorial for setting up sigstore infrastructure locally, with a focus on learning what each component is and how it functions. This tutorial is based on [Sigstore the Hard Way](https://github.com/lukehinds/sigstore-the-hard-way) with the following changes:

* Simpler: Skips steps unnecessary for local use (provisioning nodes, DNS, HAProxy, Certbot)
* Cross-platform: Initially developed on [OpenBSD](https://openbsd.org/), and compatible with most UNIX-like operating systems and shells
 
## Environment

This tutorial involves launching several foreground processes, so I highly recommend a terminal multiplexer such as [tmux](https://github.com/tmux/tmux/wiki) or [screen](https://www.gnu.org/software/screen/). For your convenience, this repository includes a [script](launch-sigstore.sh) to relaunch the daemons within a tmux session at the completion of the tutorial.

## Installation of non-sigstore prerequisites

Installing the full-stack requires the Go programming language, a SQL database, and a handful of security tools:

* Debian|Ubuntu: `sudo apt-get install -y mariadb-server git softhsm2 opensc`
* Fedora: `sudo dnf install mariadb-server git go softhsm opensc`
* FreeBSD: `doas pkg install mariadb105-server git softhsm2 opensc`
* macOS: `brew install mariadb go softhsm opensc`
* OpenBSD: `doas pkg_add mariadb-server git go softhsm2 opensc`
* NetBSD: `doas pkgin install mariadb-server git go softhsm2 opensc`

Verify that the Go version in your path is v1.16 or higher:

```shell
go version
```

If your Go version is too old, uninstall it and install the latest from https://go.dev/dl/

## MariaDB

While Sigstore can use multiple database backends, this tutorial uses MariaDB. Assuming you've installed the pre-requisites though, we can run the following to start the database up locally in a locked-down fashion:

* OpenBSD: `doas mysql_install_db && doas rcctl start mysqld && doas mysql_secure_installation`
* Debian: `sudo mysql_secure_installation`
* Fedora: `sudo systemctl start mariadb && sudo mysql_secure_installation`
* FreeBSD: TODO
* macOS: `sudo brew services start mariadb && sudo mysql_secure_installation`

During the secure script, I recommend the following answers: `nYYYY`

## Database Schema

Rekor is sigstores signature transparency log. This will setup the database tables that will be used by Trillian:

We're going to need to check the repository out to setup the database tables that will be used by Trillian:

```shell
mkdir -p $HOME/sigstore-local/src
cd $HOME/sigstore-local/src
git clone https://github.com/sigstore/rekor.git
cd rekor/scripts
sudo sh -x createdb.sh
```

## Trillian

Trillian is an append-only log for storing records. It's also going to use the MariaDB database we setup in the previous step. To install it:

```
go install github.com/google/trillian/cmd/trillian_log_server@latest
go install github.com/google/trillian/cmd/trillian_log_signer@latest
go install github.com/google/trillian/cmd/createtree@latest
```

Trillian has two daemons, first is the log server:

```shell
$HOME/go/bin/trillian_log_server -http_endpoint=localhost:8090 -rpc_endpoint=localhost:8091 --logtostderr
```

Then is the log signer:

```shell
$HOME/go/bin/trillian_log_signer --logtostderr --force_master --http_endpoint=localhost:8190 -rpc_endpoint=localhost:8191
```

NOTE: We'll use the `createtree` program we just installed later in the Certificate Transparency step.

## Rekor

Rekor is sigstores signature transparency log. Install it from source:

```shell
cd $HOME/sigstore-local/src/rekor
pushd cmd/rekor-cli && go install && popd
pushd cmd/rekor-server && go install && popd
```

Start rekor:

```shell
$HOME/go/bin/rekor-server serve --trillian_log_server.port=8091 --enable_retrieve_api=false
```

Test rekor:

```shell
cd $HOME/sigstore-local/src/rekor
$HOME/go/bin/rekor-cli upload --artifact tests/test_file.txt --public-key tests/test_public_key.key --signature tests/test_file.sig \
  --rekor_server http://localhost:3000
```

If it works, the following will be output:

`Created entry at index 0, available at: http://127.0.0.1:3000/api/v1/log/entries/d2f305428d7c222d7b77f56453dd4b6e6851752ecacc78e5992779c8f9b61dd9`

Optionally, you may inspect the rekor record using:

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

For this demonstration, we'll use GitHub to authenticate requests. Visit [GitHub: Register a new OAuth Application](https://github.com/settings/applications/new), and fill in the form accordingly:

* Application Name: `My Local Sigstore Adventure`
* Homepage URL, use `http://localhost/`
* Authorization callback URL: `http://localhost:5556/auth/callback`

When you click **Register Application**, it will output a client ID and secret. Save them to your environment:

```shell
export GITHUB_CLIENT_ID=<your ID> GITHUB_CLIENT_SECRET=<your secret>
```

Create a Dex configuration which answer local OAuth requests, delegating the authentication to GitHub:

```shell
printf "\
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

logger:
  level: "debug"
  format: "json"

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

SoftHSM is an implementation of a cryptographic store accessible through a PKCS #11 interface. You can use it to explore PKCS #11 without having a Hardware Security Module.

```shell
mkdir -p $HOME/sigstore-local/tokens && printf "\
directories.tokendir = $HOME/sigstore-local/tokens
log.level = DEBUG
" > $HOME/sigstore-local/softhsm2.conf

export SOFTHSM2_CONF=$HOME/sigstore-local/softhsm2.conf
```

This will create your first token:

```shell
softhsm2-util --init-token --slot 0 --label fulcio
```

Set the pin to `2324` or memorize your alternative PIN.

## OpenSC

Configure OpenSC:

* (FreeBSD|OpenBSD|NetBSD): `export PKCS11_MOD=/usr/local/lib/softhsm/libsofthsm2.so`
* Debian|Ubuntu: `export PKCS11_MOD=/usr/lib/softhsm/libsofthsm2.so`
* Fedora: `export PKCS11_MOD=/usr/lib64/libsofthsm2.so`
* macOS: `export PKCS11_MOD=$(brew --prefix softhsm)/lib/softhsm/libsofthsm2.so`

Use OpenSC to create a CA cert:

```shell
SOFTHSM2_CONF=$HOME/sigstore-local/softhsm2.conf pkcs11-tool --module=$PKCS11_MOD \
  --login --login-type user --keypairgen --id 1 --label PKCS11CA --key-type EC:secp384r1
```

## Fulcio

fulcio is a free Root-CA for code signing certs, issuing certificates based on an OIDC email address.

```shell
cd $HOME/sigstore-local/src
git clone https://github.com/sigstore/fulcio.git
cd fulcio
go install .
```

If you are on OpenBSD and hit the error `ld: error: unable to find library -ldl`, you'll need to override some obsolete dependencies:

```shell
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

Create a CA:

```shell
SOFTHSM2_CONF=$HOME/sigstore-local/softhsm2.conf $HOME/go/bin/fulcio createca --org=acme --country=USA \
  --locality=Anytown --province=AnyPlace --postal-code=ABCDEF --street-address=123 Main St --hsm-caroot-id 1 \
  --out fulcio-root.pem
```

Populate the Fulcio configuration file:


```shell
printf '
{
  "OIDCIssuers": {
    "http://localhost:5556": {
      "IssuerURL": "http://localhost:5556",
      "ClientID": "sigstore",
      "Type": "email"
    }
  }
}
' > $HOME/sigstore-local/config/fulcio.json
```

Start Fulcio:

```shell
SOFTHSM2_CONF=$HOME/sigstore-local/softhsm2.conf $HOME/go/bin/fulcio serve \
  --config-path=config/fulcio.json --ca=pkcs11ca --hsm-caroot-id=1 --ct-log-url=http://localhost:6105/sigstore \
  --host=127.0.0.1 --port=5000
```

**NOTE: Older versions of fulcio should use --ca=fulcioca**

If it is working, you will see a message similar to:

`2022-01-27T16:35:11.359-0800	INFO	app/serve.go:173	127.0.0.1:5000`

## Certificate Transparency Server

```shell
go install github.com/google/certificate-transparency-go/trillian/ctfe/ct_server@latest
```

Next we need to setup a private key. I'll use 2324 again, but you can use anything so long as you remember the passphrase:

```shell
cd $HOME/sigstore-local
openssl ecparam -genkey -name prime256v1 -noout -out unenc.key
openssl ec -in unenc.key -out privkey.pem -des
rm unenc.key
```

The Trillian system is multi-tenant: a single Trillian system can support multiple independent Merkle trees. This means that our particular tree for holding Web PKI certificates needs to be provisioned in the system:


```shell
$HOME/go/bin/createtree --admin_server localhost:8091
```

This command will output a long log ID number. Save it to your environment:

```shell
export LOG_ID=<log id>
```

Then populate the Certificate Transparency configuration file, filling <password> in with the certificate password you just used:

```shell
PASS=<password> printf "\
config {
  log_id: $LOG_ID
  prefix: \"sigstore\"
  roots_pem_file: \"$HOME/sigstore-local/fulcio-root.pem\"
  private_key: {
    [type.googleapis.com/keyspb.PEMKeyFile] {
       path: \"$HOME/sigstore-local/privkey.pem\"
       password: \"$PASS\"
    }
  }
}
" > $HOME/sigstore-local/ct.cfg
```

Next, start the certificate transparency server:

```shell
$HOME/go/bin/ct_server -logtostderr -log_config $HOME/sigstore-local/ct.cfg -log_rpc_server localhost:8091 -http_endpoint 0.0.0.0:6105
```

If it's successful, the output will look like:

```
I0128 11:42:16.401794   65425 main.go:121] **** CT HTTP Server Starting ****
I0128 11:42:16.401907   65425 main.go:174] Using regular DNS resolver
I0128 11:42:16.401915   65425 main.go:181] Dialling backend: name:"default" backend_spec:"localhost:8091"
I0128 11:42:16.510549   65425 main.go:306] Enabling quota for requesting IP
I0128 11:42:16.510562   65425 main.go:316] Enabling quota for intermediate certificates
I0128 11:42:16.511090   65425 instance.go:85] Start internal get-sth operations on sigstore (8494167753837750461)
```


## Registry

While sigstore can use any Container Registry, in the interest of keeping things local, we'll install a very basic one for testing:
 

```shell
go install github.com/google/go-containerregistry/cmd/registry@latest
```

This will begin the local registry - emitting no output until we talk to it.

```shell
$HOME/go/bin/registry
```

We'll use `ko` to push an unsigned test image to our local registry, as it is multi-platform and does not require Docker:

```shell
go install github.com/google/ko@latest
cd $HOME/sigstore-local/src/rekor/cmd
KO_DOCKER_REPO=localhost:1338/local $HOME/go/bin/ko publish ./rekor-cli
```

## Basic signing with cosign

Install the latest release:

```shell
go install github.com/sigstore/cosign/cmd/cosign@latest
```

The most basic usage of cosign skips Dex, Fulcio, and Rekor entirely by using a local keypair. You can use any password you like here:
  
```shell
cd $HOME/sigstore-local
$HOME/go/bin/cosign generate-key-pair
```

Sign the container we published to the local registry:
  
```shell
$HOME/go/bin/cosign sign --key cosign.key localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest
```
  
And validate the signature:
  
```shell
$HOME/go/bin/cosign verify --key cosign.pub localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9 || echo OHNO
```

The successful verification output looks verbose and scary, but everything checks out:
 
  
```
Verification for localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
  - Any certificates were verified against the Fulcio roots.

[{"critical":{"identity":{"docker-reference":"localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9"},"image":{"docker-manifest-digest":"sha256:3a46c2e44bfe8ea0231af6ab2f7adebd0bab4a892929b307c0b48d6958863a4d"},"type":"cosign container image signature"},"optional":null}]
```  
  
One can also sign non-container artifacts using `cosign` - see https://github.com/sigstore/cosign/#working-with-other-artifacts  
  
## cosign + rekor + fulcio (EXPERIMENTAL)
  
Now we will try to use some experimental features of Fulcio: Integration with the Rekor transparency log and keyless signatures using the Fulcio CA. Fulcio will uinstead rely on a combination of certificates stored in SoftHSM and the OIDC tokens provided by Dex and Github:
   
Sign the container:

```shell
COSIGN_EXPERIMENTAL=1 $HOME/go/bin/cosign sign \
   --oidc-issuer "http://localhost:5556" --fulcio-url "http://localhost:5000" --rekor-url \
   "http://localhost:3000" localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest
```

**NOTE: If Fulcio panics with 'index out of range`, patch in https://github.com/sigstore/fulcio/pull/370**

**NOTE: If you are running this tutorial on a non-local machine, wait 2 minutes for the `Enter verification code` prompt, and then forward the Dex webserver port to your local workstation using `ssh -L 5556:127.0.0.1:5556 <dex server>`. Then you can visit the URL it outputs and manually enter in the verification code.**
  

UNDER DEVELOPMENT - this step fails with:
 
`main.go:46: error during command execution: signing [localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest]: getting signer: getting key from Fulcio: verifying SCT: failed to verify ECDSA signature`

 This is probably because of the self-signed nature of our certificates. More research is required.

  
