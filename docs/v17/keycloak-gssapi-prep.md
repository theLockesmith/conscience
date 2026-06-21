# Keycloak LDAP Federation — GSSAPI Bind Migration Prep

Source-dive deliverable for task #86. Pairs with #87 (apply), which
remains BLOCKED on the AD-session keytab being landed in the
`keycloak-krb5` Secret in the `keycloak` namespace.

**Date scoped:** 2026-06-21
**Keycloak version in prod:** 26.5.0 (`quay.io/keycloak/keycloak:26.5.0`)
**Realm:** `coldforge` (CR `KeycloakRealmImport/coldforge-realm`)

---

## Current state (simple bind over LDAPS)

The realm's LDAP federation provider (`name: "Active Directory"`) is
configured by these keys in the `coldforge-realm` KeycloakRealmImport
under `spec.realm.components["org.keycloak.storage.UserStorageProvider"]`:

| Key | Current value |
|---|---|
| `providerId` | `ldap` |
| `connectionUrl` | `ldaps://samba-ad-dc-0.ad.coldforge.net:636 ldaps://samba-ad-dc-1.ad.coldforge.net:636` |
| `bindDn` | `CN=Service Account,OU=Users,OU=Service,DC=ad,DC=coldforge,DC=net` |
| `bindCredential` | *(plaintext service-account password — see Security note)* |
| `editMode` | `READ_ONLY` |
| `usersDn` | `DC=ad,DC=coldforge,DC=net` |
| `authType` | *(unset; defaults to `simple`)* |

### Security note (motivates this work)

The service account password is currently *plaintext in the
KeycloakRealmImport manifest*, which means it's in the Atlas repo. The
single best reason to do this migration is to replace
bindDn+bindCredential with a keytab so the secret rotates via standard
AD keytab procedures and never appears in YAML.

## What's needed to switch to GSSAPI bind

Keycloak's `LDAPContextManager.java` (federation/ldap module) shows that
`authType` is passed *literally* to JNDI's
`Context.SECURITY_AUTHENTICATION`:

```java
String authType = ldapConfig.getAuthType();
if (authType != null) {
    ldapContext.addToEnvironment(
        Context.SECURITY_AUTHENTICATION, authType);
}
```

JNDI accepts `GSSAPI` as a valid value (SASL Kerberos) even though
Keycloak's admin console dropdown only exposes `none` / `simple`.
This means: **we set `authType: GSSAPI` via the REST API or the
KeycloakRealmImport CR directly** — the admin UI is just a visual
limitation, not a server-side one.

### Server-side prerequisites on the Keycloak pod

GSSAPI bind requires the JVM's Krb5LoginModule to have credentials.
That means three files mounted into the pod:

1. **`/etc/krb5.conf`** — Kerberos client config. Names the realm,
   KDCs, etc. ConfigMap-mount.
2. **`/etc/keycloak/krb5.keytab`** — Service-account keytab, exported
   from AD for the service principal Keycloak will bind as. **Secret-
   mount (mode 0400, owned by 1000:0 for the Keycloak container's
   non-root user).** This is the blocker for #87.
3. **`/etc/keycloak/jaas.conf`** — JAAS login config that
   Krb5LoginModule reads. Inline-able via a ConfigMap. Required entry:

   ```
   com.sun.security.jgss.initiate {
       com.sun.security.auth.module.Krb5LoginModule required
       useKeyTab=true
       keyTab="/etc/keycloak/krb5.keytab"
       principal="ldap-service@AD.COLDFORGE.NET"
       storeKey=true
       doNotPrompt=true;
   };
   ```

### JVM flags

Set via `JAVA_OPTS_APPEND` in the Keycloak CR's container env:

```
-Djava.security.krb5.conf=/etc/krb5.conf
-Djava.security.auth.login.config=/etc/keycloak/jaas.conf
-Djavax.security.auth.useSubjectCredsOnly=false
```

The third flag lets JNDI ask the LoginModule for credentials directly
rather than expecting them on the calling Subject.

### Keycloak CR changes (`Keycloak/coldforge-keycloak`)

In `spec.unsupported.podTemplate.spec`:

```yaml
spec:
  containers:
    - name: keycloak
      env:
        - name: JAVA_OPTS_APPEND
          value: >-
            -Djava.security.krb5.conf=/etc/krb5.conf
            -Djava.security.auth.login.config=/etc/keycloak/jaas.conf
            -Djavax.security.auth.useSubjectCredsOnly=false
      volumeMounts:
        - name: krb5-conf
          mountPath: /etc/krb5.conf
          subPath: krb5.conf
          readOnly: true
        - name: keycloak-krb5
          mountPath: /etc/keycloak/krb5.keytab
          subPath: krb5.keytab
          readOnly: true
        - name: keycloak-jaas
          mountPath: /etc/keycloak/jaas.conf
          subPath: jaas.conf
          readOnly: true
  volumes:
    - name: krb5-conf
      configMap:
        name: keycloak-krb5-conf
    - name: keycloak-krb5
      secret:
        secretName: keycloak-krb5      # <-- BLOCKER for #87
        defaultMode: 0400
    - name: keycloak-jaas
      configMap:
        name: keycloak-jaas-conf
        defaultMode: 0400
```

### KeycloakRealmImport changes

Replace the simple-bind block with the GSSAPI block. For
`spec.realm.components["org.keycloak.storage.UserStorageProvider"][0].config`:

```yaml
# Remove:
bindDn: [...]
bindCredential: [...]

# Add / change:
authType: ["GSSAPI"]
useKerberosForPasswordAuthentication: ["false"]   # bind-only; password auth still goes via STARTTLS-bind or SPNEGO separately
```

The realm-level Kerberos section (under `spec.realm.kerberosRealm`,
`spec.realm.serverPrincipal`, `spec.realm.keyTab`) is ONLY required
if you also want SPNEGO browser SSO. For LDAP-bind-only GSSAPI it's
NOT needed — the realm-level Kerberos config controls user-facing
SPNEGO authentication, not the federation provider's own bind.

### `editMode` interaction

`READ_ONLY` continues to work with GSSAPI. No change needed; we're
read-only against AD today and that's the right posture.

## Apply order (for #87 when keytab lands)

1. Create the `keycloak-krb5` Secret with key `krb5.keytab` from the
   ad-side exported keytab. (Blocker. Operator-side.)
2. Create `keycloak-krb5-conf` ConfigMap with `krb5.conf` (realm,
   KDCs).
3. Create `keycloak-jaas-conf` ConfigMap with `jaas.conf`.
4. `atlas kube apply` the Keycloak CR change (`JAVA_OPTS_APPEND` +
   the three new volume mounts). Triggers a rolling restart.
5. Wait for both `coldforge-keycloak-{0,1}` pods to reach Ready 1/1.
6. Test the JVM can read the keytab + acquire a ticket on its own
   before changing the federation provider:
   ```
   oc-atlantis -n keycloak exec coldforge-keycloak-0 -- \
       /opt/keycloak/bin/kc.sh kerberos test (if available, else
       run a small kinit in the container)
   ```
7. Update the KeycloakRealmImport with `authType: GSSAPI`, remove
   `bindDn` + `bindCredential`. Apply via the realm-import controller.
8. Trigger a `Sync all users` from the admin console (or REST) to
   confirm the federation provider can list users via GSSAPI bind.

## Pre-rotation: invalidate the leaked password

Once GSSAPI bind is verified end-to-end, the AD service account
password that lived in the Atlas repo MUST be rotated. The keytab
moves on without it.

