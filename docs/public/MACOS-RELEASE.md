# macOS Developer ID release

An Apple Development signature with a device-limited provisioning profile is a local testing build. It must not be presented as a public macOS distribution.

Build the intended Release application first. Prepare an existing **Developer ID Application** private identity in Keychain and an Apple-issued macOS profile for the explicit compatibility App ID `app.smail.desktop`. The profile must authorize CloudKit container `iCloud.app.smail.workspace` in **Production**, contain the selected certificate, enable `ProvisionsAllDevices`, and have no device list or debug task access.

Keep the profile and a file containing its certificate SHA1 under ignored local storage. The script never creates certificates, changes trust, updates provisioning, or copies an application backup.

```sh
python3 scripts/sign-distribution-app.py \
  --app dist/Morrow.app \
  --profile .local/signing/distribution.provisionprofile \
  --identity-file .local/signing/developer-id.sha1 \
  --check
```

`--check` is read-only. `readyToSign` confirms prepared inputs; `distributionSignatureVerified` independently describes the application's existing signature. A development signature can have valid prepared release inputs while still failing distribution verification.

After successful preflight, stop the application and repeat the command without `--check`. It signs only the main executable bundle in place, using hardened runtime, a secure Apple timestamp, minimal profile-derived App ID/team/CloudKit entitlements, and the embedded Production profile. It adds no Keychain access group, ubiquity document or KV permission; existing credential service namespaces retain their behavior. Unexpected nested executable code is rejected and requires its own signing plan; the script never uses recursive force-signing to hide it. Verification checks the signature, exact selected certificate, Developer ID authority chain, timestamp, entitlements, profile bytes, Production configuration, and unchanged unrelated resources.

Receipts remain under `.local/evidence/private/`. Decoded CMS, certificate subjects, and command output are handled in private temporary storage. Console output contains status categories, public app version information, and a relative receipt path. Failed signing is not a release: repair the prepared inputs or rebuild the intended application before retrying.

## Notarization and distribution

Developer ID signing alone does not establish Apple notarization acceptance. Package the verified app and submit it using your existing notarization credentials:

```sh
ditto -c -k --keepParent dist/Morrow.app dist/Morrow-notarization.zip
asc notarization submit --file dist/Morrow-notarization.zip --wait
```

Only after Apple reports **Accepted**, staple the ticket and verify Gatekeeper assessment before publishing a release asset:

```sh
xcrun stapler staple dist/Morrow.app
xcrun stapler validate dist/Morrow.app
spctl --assess --type execute --verbose=4 dist/Morrow.app
```

Production CloudKit schema readiness and user opt-in are separate from code signing. Never upload mailbox data, signing credentials, or local acceptance evidence in the release archive. Update the download manifest with the verified artifact's actual version, size, and SHA256 after publishing.
