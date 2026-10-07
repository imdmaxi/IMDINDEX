#!/usr/bin/env bash
# Publishes the source of every deployed $COMPANY contract to Sourcify and Blockscout, so scanners (GoPlus,
# Quick Intel, DexScreener, GMGN) see them as open source. Needs no API keys. Run from contracts/ after Deploy.s.sol:
#   ./script/verify.sh
set -euo pipefail

RPC="${RPC:-https://robinhood.drpc.org}"
BLOCKSCOUT="https://robinhoodchain.blockscout.com/api/"
DEPLOYMENT="${DEPLOYMENT:-deployments/robinhood.json}"

field() { python3 -c "import json,sys; print(json.load(open('$DEPLOYMENT'))['$1'])"; }

verify() {
  local addr="$1" target="$2"
  for verifier in sourcify blockscout; do
    local extra=()
    [ "$verifier" = blockscout ] && extra=(--verifier-url "$BLOCKSCOUT")
    echo "== $target at $addr on $verifier"
    forge verify-contract "$addr" "$target" --chain 4663 --rpc-url "$RPC" --guess-constructor-args \
      --verifier "$verifier" ${extra[@]+"${extra[@]}"} --watch || echo "   (failed or already verified)"
  done
}

verify "$(field token)" src/CompanyToken.sol:CompanyToken
verify "$(field hook)" src/CompanyHook.sol:CompanyHook
verify "$(field router)" src/CompanyRouter.sol:CompanyRouter
verify "$(field ethRouter)" src/CompanyEthRouter.sol:CompanyEthRouter

echo
echo "Then check the token on GoPlus:"
echo "  curl -s 'https://api.gopluslabs.io/api/v1/token_security/4663?contract_addresses=$(field token)'"
