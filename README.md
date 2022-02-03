# sigstore-the-local-way (UNDER DEVELOPMENT)

This is a tutorial for setting up sigstore infrastructure locally, with a focus on learning what each component is and how it functions. This tutorial is based on [Sigstore the Hard Way](https://github.com/lukehinds/sigstore-the-hard-way) and [Bring-your-own sTUF with TUF](https://blog.sigstore.dev/sigstore-bring-your-own-stuf-with-tuf-40febfd2badd) with the following changes:

* Simpler: Skips steps unnecessary for local use (provisioning nodes, DNS, HAProxy, Certbot)
* Updated: Incorporates the latest changes to sigstore
* Cross-platform: Initially developed on [OpenBSD](https://openbsd.org/), and compatible with most UNIX-like operating systems and shells

Similar in concept to [Dante's Inferno](https://en.wikipedia.org/wiki/Inferno_(Dante)), this tutorial adventures through the 3-circles of sigstore:

1. Signing and verifying a container using a local OCI registry
2. Signing and verifying a container using a local OCI registry + Rekor
3. Keyless signing and verifying a container using a local OCI registry + Rekor + Fulcio

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

## Level 1: Basic signing against a local registry

### 1.1: Starting a local registry

While sigstore can use any Container Registry, in the interest of keeping things local, we'll install a basic one for testing:

```shell
go install github.com/google/go-containerregistry/cmd/registry@latest
```

This will begin the local registry - emitting no output until artifacts are stored:

```shell
$HOME/go/bin/registry
```

### 1.2: Pushing an unsigned image to the local registry

For this demo, we're going to build the rekor-cli tool into an unsigned image and push it locally.

Check out rekor codebase:

```shell
mkdir -p $HOME/sigstore-local/src
cd $HOME/sigstore-local/src
git clone https://github.com/sigstore/rekor.git

```

We'll use `ko` to build and push the image, as it does not require Docker or Podman to be installed:

```shell
go install github.com/google/ko@latest
cd $HOME/sigstore-local/src/rekor/cmd
KO_DOCKER_REPO=localhost:1338/demo $HOME/go/bin/ko publish ./rekor-cli
```

### 1.3: Keyed-signing with cosign

Install the latest release:

```shell
go install github.com/sigstore/cosign/cmd/cosign@latest
```

The most basic usage of cosign uses a local keypair. You can use any password you like:

```shell
cd $HOME/sigstore-local
$HOME/go/bin/cosign generate-key-pair
```

Sign the container we published to the local registry:

```shell
$HOME/go/bin/cosign sign --key cosign.key localhost:1338/demo/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest
```

And validate the signature:

```shell
$HOME/go/bin/cosign verify --key cosign.pub localhost:1338/demo/rekor-cli-e3df3bc7cfcbe584a2639931193267e9 || echo OHNO
```

The successful verification output looks verbose and scary, but everything checks out:

```
Verification for localhost:1338/demo/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
  - Any certificates were verified against the Fulcio roots.

[{"critical":{"identity":{"docker-reference":"localhost:1338/demo/rekor-cli-e3df3bc7cfcbe584a2639931193267e9"},"image":{"docker-manifest-digest":"sha256:3a46c2e44bfe8ea0231af6ab2f7adebd0bab4a892929b307c0b48d6958863a4d"},"type":"cosign container image signature"},"optional":null}]
```

It is also possible to sign binaries or other blobs of text using `cosign`, see [Working with other artifacts](https://github.com/sigstore/cosign/#working-with-other-artifacts).


## 2.0: Certificate Transparency with Rekor

### 2.1: Creating a database backend with MariaDB

While Sigstore can use multiple database backends, this tutorial uses MariaDB. Assuming you've installed the pre-requisites though, we can run the following to start the database up locally in a locked-down fashion:

* OpenBSD: `doas mysql_install_db && doas rcctl start mysqld && doas mysql_secure_installation`
* Debian: `sudo mysql_secure_installation`
* Fedora: `sudo systemctl start mariadb && sudo mysql_secure_installation`
* FreeBSD: TODO
* macOS: `sudo brew services start mariadb && sudo mysql_secure_installation`

During the secure script, I recommend the following answers: `nYYYY`. Once complete, create the database tables which Trillian will need:

```shell
cd $HOME/sigstore-local/src/rekor/scripts
sudo sh -x createdb.sh
```

### 2.2: Installing Trillian

Install Trillian, which is an append-only log for storing records:

```
go install github.com/google/trillian/cmd/trillian_log_server@latest
go install github.com/google/trillian/cmd/trillian_log_signer@latest
go install github.com/google/trillian/cmd/createtree@latest
```

Start the log server:


```shell
$HOME/go/bin/trillian_log_server -http_endpoint=localhost:8090 -rpc_endpoint=localhost:8091 --logtostderr
```

Start the log signer:


```shell
$HOME/go/bin/trillian_log_signer --logtostderr --force_master --http_endpoint=localhost:8190 -rpc_endpoint=localhost:8191
```

The Trillian system is multi-tenant, and can support multiple independent Merkle trees. Create the tree, and save the resulting log_id for future use:

```shell
$HOME/go/bin/createtree --admin_server localhost:8091 | tee $HOME/sigstore-local/trillian.log_id
```

### 2.3: Installing Rekor

Rekor is sigstore's certificate transparency backend. Install it from source:

```shell
cd $HOME/sigstore-local/src/rekor
pushd cmd/rekor-cli && go install && popd
pushd cmd/rekor-server && go install && popd
```

Start rekor:

```shell
$HOME/go/bin/rekor-server serve --trillian_log_server.port=8091 --enable_retrieve_api=false
```

Upload a test artifact to rekor:

```shell
cd $HOME/sigstore-local/src/rekor
$HOME/go/bin/rekor-cli upload --artifact tests/test_file.txt --public-key tests/test_public_key.key --signature tests/test_file.sig \
  --rekor_server http://localhost:3000
```

If it works, the following will be output:

`Created entry at index 0, available at: http://127.0.0.1:3000/api/v1/log/entries/d2f305428d7c222d7b77f56453dd4b6e6851752ecacc78e5992779c8f9b61dd9`

You can inspect the resulting record with:

```shell
curl -s http://127.0.0.1:3000/api/v1/log/entries/d2f305428d7c222d7b77f56453dd4b6e6851752ecacc78e5992779c8f9b61dd9
```

### 2.4: Keyed verifiable signing with Cosign & Rekor

With Rekor setup, we can now sign and upload the signature for our image, and verify against that signature:

Sign a container image uploading keys to rekor:

```shell
COSIGN_EXPERIMENTAL=1 $HOME/go/bin/cosign sign --key $HOME/sigstore-local/cosign.key \
  --rekor-url=http://localhost:3000 \
  localhost:1338/demo/rekor-cli-e3df3bc7cfcbe584a2639931193267e9

```

Verify the container against the OCI attestation and the Rekor record:

```shell
COSIGN_EXPERIMENTAL=1 $HOME/go/bin/cosign verify --key $HOME/sigstore-local/cosign.pub \
  --rekor-url=http://localhost:3000 \
  localhost:1338/demo/rekor-cli-e3df3bc7cfcbe584a2639931193267e9

```

Rekor will in-turn rely on both the OCI metadata, as well as Trillian and the MariaDB database we setup earlier to verify the certificate.

## 3.0: Keyless signing with Fulcio (EXPERIMENTAL)

### 3.1: Setting up SoftHSM

SoftHSM is an implementation of a cryptographic store accessible through a PKCS #11 interface. You can use it to explore PKCS #11 without having a Hardware Security Module.

```shel
SOFTHSM2_CONF=$HOME/sigstore-local/softhsm2.conf pkcs11-tool \
  --module=$PKCS11_MOD \
  --login \
  --login-type user \
  --keypairgen \
  --id 1 \
  --label PKCS11CA \
  --key-type EC:secp384r1
```

Create a CA root certificate:

```shell
SOFTHSM2_CONF=$HOME/sigstore-local/softhsm2.conf $HOME/go/bin/fulcio createca \
  --org=acme \
  --country=USA \
  --locality=Anytown \
  --province=AnyPlace \
  --postal-code=ABCDEF \
  --street-address="123 Main St" \
  --hsm-caroot-id 1 \
  --out $HOME/sigstore-local/ca-root.pem
```

## 3.3: Installing the Certificate Transparency Frontend

```shevll
go install github.com/google/certificate-transparency-go/trillian/ctfe/ct_server@latest
```

Next we need to setup a private key. I'll use 2324 again, but you can use anything so long as you remember the passphrase:

```shell
cd $HOME/sigstore-local
openssl ecparam -genkey -name prime256v1 -noout -out unenc.key
openssl ec -in unenc.key -out privkey.pem -des
rm unenc.key
```

Look up the Trillian log ID we previously created, and set the LOG_ID variable to the resulting value:

```shell
cat $HOME/sigstore-local/trillian.log_id

```

Then populate the Certificate Transparency configuration file, filling <password> in with the certificate password you just used:

```shell
LOG_ID=<result> PASS=<password> printf "\
config {
  log_id: $LOG_ID
  prefix: \"sigstore\"
  roots_pem_file: \"$HOME/sigstore-local/ca-root.pem\"
  private_key: {
    [type.googleapis.com/keyspb.PEMKeyFile] {
       path: \"$HOME/sigstore-local/privkey.pem\"
       password: \"$PASS\"
    }
  }
}
" > $HOME/sigstore-local/ct.cfg
```

Start the certificate transparency server:

```shell
$HOME/go/bin/ct_server -logtostderr -log_config $HOME/sigstore-local/ct.cfg -log_rpc_server localhost:8091 -http_endpoint 0.0.0.0:6105
```

If successful, the output will look like:

```
I0128 11:42:16.401794   65425 main.go:121] **** CT HTTP Server Starting ****
I0128 11:42:16.401907   65425 main.go:174] Using regular DNS resolver
I0128 11:42:16.401915   65425 main.go:181] Dialling backend: name:"default" backend_spec:"localhost:8091"
I0128 11:42:16.510549   65425 main.go:306] Enabling quota for requesting IP
I0128 11:42:16.510562   65425 main.go:316] Enabling quota for intermediate certificates
I0128 11:42:16.511090   65425 instance.go:85] Start internal get-sth operations on sigstore (8494167753837750461)
```

### 3.4: Installing Dex for OpenID authentication

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

### 3.5: Setting up Fulcio for key-less signatures

fulcio is a free Root-CA for code signing certs, issuing certificates based on an OIDC email address. To install it from source:

```shell
cd $HOME/sigstore-local/src
git clone https://github.com/sigstore/fulcio.git
cd fulcio
go install .
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
cd $HOME/sigstore-local
SOFTHSM2_CONF=$HOME/sigstore-local/softhsm2.conf $HOME/go/bin/fulcio serve \
  --config-path=config/fulcio.json --ca=pkcs11ca --hsm-caroot-id=1 --ct-log-url=http://localhost:6105/sigstore \
  --host=127.0.0.1 --port=5000
```

If it is working, you will see a message similar to:

`2022-01-27T16:35:11.359-0800	INFO	app/serve.go:173	127.0.0.1:5000`

### 3.6: Bring-your-own TUF

Cosign uses TUF as a root of trust, so we're going to need to set it up locally for key verification. Install the tuf command-line:

```shell
go install github.com/theupdateframework/go-tuf/cmd/tuf@latest
```

Create a local tuf repository:

```shell
mkdir -p $HOME/sigstore-local/tuf
cd $HOME/sigstore-local/tuf
$HOME/go/bin/tuf init --consistent-snapshot=false
```

Now generate keys for the various roles. Since we are using this for testing purposes, you can get away with an empty passphrase if you like:

```shell
$HOME/go/bin/tuf gen-key root
$HOME/go/bin/tuf gen-key targets
$HOME/go/bin/tuf gen-key snapshot
$HOME/go/bin/tuf gen-key timestamp
```

Sign the root key metadata (references `keys/root.json`):

```shell
$HOME/go/bin/tuf sign root.json
```

Download our local certificates:

```shell
curl -o staged/targets/rekor.pub http://localhost:3000/api/v1/log/publicKey
curl -o staged/targets/fulcio.crt.pem http://localhost:5000/api/v1/rootCert
$HOME/go/bin/tuf add
$HOME/go/bin/tuf snapshot
$HOME/go/bin/tuf timestamp
$HOME/go/bin/tuf commit
```

Run a local webserver to make the TUF keys fetcheable:

```shell
cd repository
python3 -m http.server --bind 127.0.0.1 8081
```

### 3.7: Keyless signing with cosign

Now we will try to use some experimental features of Fulcio: Integration with the Rekor transparency log and keyless signatures using the Fulcio CA. Fulcio will uinstead rely on a combination of certificates stored in SoftHSM and the OIDC tokens provided by Dex and Github:


**NOTE: If you running cosign on a non-local machine, wait 2 minutes for the `Enter verification code` prompt, and then forward the Dex webserver port to your local workstation using `ssh -L 5556:127.0.0.1:5556 <dex server>`. Then you can visit the URL it outputs and manually enter in the verification code.**

Add the fulcio-root certificate to our trust list:

Sign the container with our local certificate:

```shell
SSL_CERT_FILE=$HOME/sigstore-local/ca-root.pem COSIGN_EXPERIMENTAL=1 $HOME/go/bin/cosign sign \
   --oidc-issuer=http://localhost:5556 \
   --fulcio-url=http://localhost:5000 \
   --rekor-url=http://localhost:3000 \
   localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest
```

With any luck, you'll authenticate against GitHub, and get as far as this error message:

`main.go:46: error during command execution: signing [localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest]: getting signer: getting key from Fulcio: verifying SCT: failed to verify ECDSA signature`

This is because we haven't told cosign to trust our local TUF instance. To do so, run:

```shell
cosign initialize  --mirror=http://localhost:8081 --root $HOME/sigstore-local/tuf/repository/root.json
```

And try again:

```shell
SSL_CERT_FILE=$HOME/sigstore-local/ca-root.pem COSIGN_EXPERIMENTAL=1 $HOME/go/bin/cosign sign \
   --oidc-issuer=http://localhost:5556 \
   --fulcio-url=http://localhost:5000 \
   --rekor-url=http://localhost:3000 \
   localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest
```

**NOTE: This currently fails with:***

`main.go:46: error during command execution: signing [localhost:1338/local/rekor-cli-e3df3bc7cfcbe584a2639931193267e9:latest]: getting signer: getting key from Fulcio: verifying SCT: error verifying local metadata; local cache may be corrupt: tuf: file not found: ctfe.pub`

## 4.0: Appendix

### 4.1: Resuming the tutorial

If you have rebooted and wish to bring the local sigstore stack up again, you can do so if you have checked out this repository and have [tmux](https://github.com/tmux/tmux/wiki) installed:

```shell
sh launch-sigstore.sh
```

### 4.2: Unistalling the local sigstore installation

After killing any daemons started:

```shell
sudo mysql -u root -e "DROP DATABASE IF EXISTS test;"
rm -Rf $HOME/sigstore-local
```

