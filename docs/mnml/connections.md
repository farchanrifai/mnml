# Personal account connections

mnml connects Gmail, Calendar, Drive, and Notion independently of the selected
AI provider. No service desktop app or connector helper is required. Connect
accounts in **Settings > Connections** and choose which accounts can be used in
the current space. Antigravity can search those accounts automatically when a
question needs their content. No connection chip is required. Use **@** or the
chat's **Connections** menu to choose a particular account and service instead;
explicit choices narrow that chat's searches to those sources. Ask your question;
mnml performs requested searches and document reads and supplies bounded results
to the same warm chat worker. Source links identify retrieved evidence. Writes
are optional per account and space, and require review in the chat before each
change. Gmail and Calendar remain read-only.

## Google setup for your own account

The OAuth client below serves all your accounts and spaces. Import its JSON once
on this Mac; it does not need to be recreated or imported per account or space.
Each account is authorized separately through **Connect Google**. Google and
Notion connections are separate from the Antigravity subscription login.

1. Open the [Google Cloud console](https://console.cloud.google.com/) and sign
   in to the account that should own the mnml project. This can be your personal
   account even when you later connect another Google account.
2. Open the project selector beside the Google Cloud logo, choose **New
   project**, name it **mnml Personal**, and create it. Select that project after
   it is created. Keep the same project selected for all following steps.
3. Go to **APIs & Services > Library**. Search for **Gmail API**, open it, and
   click **Enable**. Repeat for **Google Calendar API** and **Google Drive API**.
   [Google's API setup guide](https://developers.google.com/workspace/guides/enable-apis)
4. Go to **Google Auth platform > Branding**. If you see **Get Started**, click
   it. Enter **mnml Personal** as the app name, choose your own support email,
   select **External** as the audience, and enter your own contact email. Review
   the Google API Services User Data Policy and complete the setup if you agree.
   External lets this one client serve your personal and eligible work accounts;
   Internal is restricted to the project's Google Workspace organization.
   [Consent setup](https://developers.google.com/workspace/guides/configure-oauth-consent)
5. In **Audience**, initially leave the project in **Testing**. Under **Test
   users**, choose **Add users**, enter the Google account you will connect,
   and save. Add every additional account you intend to authorize while the
   project remains in Testing.
6. In **Data Access > Add or remove scopes**, select or manually add the scopes
   below, then save. Google may label `email` as
   `https://www.googleapis.com/auth/userinfo.email`; that is its equivalent
   account-identity permission.

   | Permission | Scope |
   | --- | --- |
   | Account identity | `openid`, `email` |
   | Read Gmail | `https://www.googleapis.com/auth/gmail.readonly` |
   | Read events | `https://www.googleapis.com/auth/calendar.events.readonly` |
   | Read Drive files | `https://www.googleapis.com/auth/drive.readonly` |

   Optional document and file writes use
   `https://www.googleapis.com/auth/drive`. This permission is broader than
   reading: Google permits editing and moving files the account can access.
   Enable it only for accounts where you want mnml to perform those actions.
   [Drive authorization scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)

7. In **Google Auth platform > Clients**, click **Create client**. Choose
   **Desktop app**, name it **mnml Mac**, and click **Create**. Download the
   client JSON from the creation dialog or client details. Keep this file
   privately on your Mac. Use the Desktop app type even though mnml is a browser;
   it is the native Mac app performing authorization.
   [Create credentials](https://developers.google.com/workspace/guides/create-credentials)
8. Open the normal **mnml** app, then **Settings > Connections**. Under
   **Desktop app client**, choose **Import JSON…** and select the downloaded
   file. Once **Credentials imported on this Mac** appears, **Connect Google**
   becomes available. Import once; additional accounts reuse this client.
9. Click **Connect Google**, select your intended account in the system browser,
   and review the requested read permissions. If Google displays a testing or
   unverified-app notice, verify that it is your own project. Only you should
   decide whether to proceed. Complete consent and wait for mnml to list your
   email with Gmail, Calendar and Drive. Only services whose scopes you granted
   appear. mnml receives the callback on a temporary `127.0.0.1` listener using
   PKCE and state validation; you do not enter callback ports in Cloud Console.
   [Desktop authorization](https://developers.google.com/identity/protocols/oauth2/native-app)
10. Open a mnml chat and select **Antigravity** as the AI provider. Its CLI
    subscription login is separate from the service account you just connected.
    In **Settings > Connections**, confirm **Use in [space name]** is enabled for
    the intended account. Leave **Automatic search in [space name]** enabled to
    let Antigravity search Gmail, Calendar or Drive when useful. To request one
    source explicitly, type **@Gmail**, **@Calendar**, **@Drive**, your account's
    label, or its email, then choose the matching account/service row.
11. Test each service with a question for which you know a result: **Find my
    emails about [a distinctive subject] from the last week**; **Find meetings
    about [a keyword] in the next 30 days**; **Find the Drive document named
    [a distinctive title] and summarize it**. Check the source link and account
    label on the answer.
12. Later accounts use **Connect Google > choose another account > approve**.
    No JSON import is required again. The newly connected account is enabled in
    the current space; enable it in other spaces only if you want it used there.

### Everyday personal use after the first test

External apps in **Testing** receive authorizations and refresh tokens that
expire after seven days for these data scopes. Reconnecting needs only
**Connect Google**, not another JSON import.
[Google's audience and expiry rules](https://support.google.com/cloud/answer/15549945)

After the first test works, you can consider **Audience > Publish app** to set
the OAuth project **In production** for ongoing personal use. This changes the
OAuth audience status; it does not publish mnml's source or distribute the app.
The seven-day Testing limit no longer applies, but refresh tokens can still
expire or be revoked for other reasons. Google provides a personal-use
verification exception for your own/few personally known users. An unverified
warning and account cap can remain; In production does not mean verified.
Managed Workspace policies can also block authorization.
[Personal-use exception](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification#personal-use)

Keep the downloaded JSON private. mnml stores its imported credentials in
Keychain; it does not require the file again after import. Changing imported
credentials affects new connections, while existing grants keep their original
OAuth client.

### If setup fails

- **Connect Google is disabled:** import the Desktop OAuth JSON first.
- **Import rejected:** download the Desktop app client's JSON; Web-client,
  service-account, and API-key files are not supported.
- **Access denied in Testing:** add that exact account to Audience > Test users.
- **API not enabled:** enable the relevant API in the project that owns this
  OAuth client, rather than another selected project.
- **Work account blocked:** your Workspace administrator may need to permit
  the OAuth app. The personal Gmail account cannot override work policies.
- **Expired connection:** click Connect Google again and approve access.
- **No connected services:** grant the relevant Gmail/Calendar/Drive read
  scopes, then reconnect. Identity-only sign-in cannot search those services.
- **No search result:** confirm the account's **Use in [space name]** checkbox
  is enabled. If automatic search is off, select the source with **@** or the
  chat's **Connections** menu. Calendar currently reads the primary calendar,
  and Drive file-format limits are described below.

## Notion setup

Click **Connect Notion** and complete the workspace access screen in your
system browser. No separate public integration or client JSON is needed:
mnml discovers Notion's official hosted MCP OAuth server, registers a native
client, and uses PKCE. Notion's permission screen can grant broader workspace
capability than reading. After connecting, mnml initially uses search/fetch.
Choose **Allow Notion writes** on the account card to enable creating and
appending notes in the current space. Every write still needs review in the
chat. Availability of features depends on your workspace's permissions and
plan.
[Notion's native-client guide](https://developers.notion.com/guides/mcp/build-mcp-client)

## Enable document and file writes

Read access continues to work without this setup. Write access is a separate
choice for each account and each space; automatic search does not turn it on.

For a Google account:

1. Open the same Google Cloud project that owns your imported Desktop client.
2. Go to **APIs & Services > Library** and enable **Google Sheets API** and
   **Google Docs API**. The existing **Google Drive API** is also required.
3. In **Google Auth platform > Data Access**, add
   `https://www.googleapis.com/auth/drive` and save. Keep the existing Gmail
   and Calendar read permissions. If the project remains in Testing, the
   account must still be listed under **Audience > Test users**.
4. In mnml **Settings > Connections**, enable **Use in [space name]** for the
   account, then click **Enable writes…**. Choose the same Google account and
   review the new permission screen. This upgrades that account's grant; no
   new OAuth client or JSON import is needed.
5. Confirm **Allow writes in [space name]** is enabled. In another space, enable
   it separately when wanted. Clearing this checkbox keeps read access and
   stops new writes in that space.

For Notion, enable **Use in [space name]**, then choose **Allow Notion writes**
on the account card. Existing Notion workspace permissions still determine
which pages can be edited. Use **Allow writes in [space name]** to control each
space independently.

With Antigravity selected, ask for a concrete change. Examples:

- **Create a Google Sheet called Weekly expenses in my Work account with
  columns Date, Vendor and Amount.**
- **Write these rows into A1:C5 of the spreadsheet [name].**
- **Create a Google Doc called Meeting notes with this text: …**
- **Append this paragraph to the document [name].**
- **Move the Drive file [name] into the folder [name].**
- **Create a Notion note under [page name] with this text: …**
- **Append this checklist to the Notion page [name].**

Existing targets and destinations are resolved from retrieved sources within
the account and space allowed for the chat. Use **@Work** and choose that
account's Drive or Notion row when several accounts could apply.

A **Review write** card appears in the chat with the account, operation, target
and destination when applicable, and the content to be written. Review all of
the displayed content, then choose **Approve write** to apply it or **Cancel**
to leave the service unchanged. Approval applies to that one displayed request;
the model cannot approve its own changes. The chat remains open while waiting
for your choice. Moving a file does not delete it. Mail sending, calendar edits,
file deletion and unrestricted document replacement are not implemented.

Write previews are kept in memory and expire after ten minutes. Closing the
chat, stopping the request, or changing its account/Space permissions cancels a
pending approval. Receipts record confirmed or partial results in chat history;
an interrupted write stays marked as unconfirmed so it is not silently retried.
Sheets writes are bounded to 2,000 cells and 32 KB; prose writes to 32 KB. Docs
append to the first document tab. Drive moves support files within the same
Drive; folder moves, moves across shared-drive boundaries, and creation directly
inside a shared drive are not supported yet. Text beginning with `=` is literal
Sheet text, rather than a formula.

Source values, file metadata and destination permissions are checked again
after approval. Docs also use Google's server-enforced `requiredRevisionId`.
Sheets cell writes and Drive moves have a small concurrent-edit window between
the final read and mutation; they do not provide an atomic revision condition.

## Spaces, account labels, and explicit sources

Settings manages one list of connected accounts on this Mac. An account is
available to chats only in spaces where **Use in [space name]** is enabled.
Switch to another mnml space, open **Settings > Connections**, and choose its
accounts independently. Several Google accounts can be enabled in one space;
automatic searches can use the eligible accounts for the requested service.

Each account card has a **Label** field and **Save** button. Use names such as
**Personal account** or **Work account**. Labels appear in connection choices,
chips, and newly captured sources; the original email or workspace identity
remains visible so similar labels can be distinguished. Clearing the label
returns to the original identity.

**Automatic search** is a space setting, also accessible from the chat's
**Connections** menu. It permits relevant retrieval, rather than a background
sync or a search for every question. To choose a source explicitly, type **@**
and filter by service, label or email; click a row or use arrow keys and Return.
The resulting removable chip names one account/service. With explicit chips,
the chat searches only those selected sources. Removing the last chip returns
to the space's automatic setting. A revoked or disabled explicit selection stays
visible as **Unavailable**, preserving the restriction until you remove it.
Account connection search is available only
with Antigravity; other AI providers retain ordinary tab mentions.

## Credentials, expiry, and disconnection

Account metadata, OAuth client details, and access/refresh tokens are kept in
one Keychain item. Its service is isolated by `Store.world`: normal mnml, mnml
Test, and named probe profiles do not share connections. Secrets are never put
in chat prompts, saved turns, or diagnostics. OAuth HTTP requests reject
redirects and use only explicitly allowed official provider hosts.

Antigravity remains a constrained chat worker. Its structured lookup and write requests
are resolved by mnml's native clients, using Google REST and Notion's hosted MCP;
mnml does not give the CLI OAuth credentials, inherit its global MCP settings,
or enable its shell/browser tools. Automatic lookup currently requires
Antigravity, even though account connections are managed independently.

Refresh runs only when an access token needs it. Concurrent callers share one
refresh; a rotated Notion token is stored atomically before use. Revoked or
expired grants are removed and require reconnection. Network failures preserve
the grant so a later user action can retry.

**Disconnect** deletes mnml's local credentials. It does not revoke a grant
across other clients using your Google project or Notion workspace. To withdraw
the provider grant as well, use
[Google's third-party connections](https://myaccount.google.com/connections)
or Notion's workspace connection settings. Cancel in mnml closes its local
authorization listener; it cannot close a sign-in tab already opened in the
system browser.

The implementation has fixture tests for PKCE, callback state/address checks,
form encoding, granted services, identity persistence, official-host checks,
refresh-token preservation/rotation, concurrent refresh, cancellation, and
revocation. Real Google/Notion authorization still requires the user's own
consent; no live accounts were connected during implementation.

## Chat and resource behavior

Only accounts enabled in the current space can be searched. Explicit selections
can restrict that set further. Search results carry a service
and account reference; document reads must refer to a result already found in
that chat. Each question allows at most six exchanges (including up to three
write proposals) and 24,000 characters
of fetched evidence, with at most 16,000 characters from any one read. Each search
reads at most three accounts and returns at most ten matches. If more than three
accounts are enabled for a service, choose a specific account using its label or
`@`; the app refuses an overbroad search before reading any account. Downloads
are capped at 8 MB. Calendar searches currently use the primary calendar; Drive
supports Google Docs, Sheets, text/CSV, and text PDFs. Sheets exports contain only
the first sheet; scanned PDFs need OCR and are not supported.

Connections do not run a background helper or poll accounts. OAuth refresh is
on demand and does not call the AI. AI searches can require several model
responses (planning, reading, answering), so they consume more quota than a plain
question. Those exchanges reuse the same warm Antigravity process and its cache;
the existing two-worker cap, idle warning and automatic process cleanup still
apply. Changing a chat's space, selected sources, labels or account eligibility
invalidates its warm context when necessary. Disconnecting an account stops affected warm workers so their retrieved
content cannot continue silently in a live session. Saved answers and their
source links remain in the chat.

## Validation and installed build

Installed into the normal `/Applications/mnml.app` as **1.0.4 (202610041721)**
on 2026-10-04. The installed binary matches the packaged binary, and strict
signature verification passed.

### Read connection checkpoint

The earlier read connection build `202610041622` was verified as follows:

- Release regression suite: 209 tests discovered, 207 passed and two opt-in live
  CLI checks skipped, with no failures. Coverage includes OAuth, retrieval,
  exact service/account selection, space policy, metadata persistence, and warm
  worker invalidation. Seven download lifecycle tests passed separately.
- The installed official Antigravity CLI passed a labeled-account routing test
  against synthetic HTTP data: with Personal and Work available, it chose only
  Work, searched and read the approval, then answered a calculation follow-up in
  the same process without another service read. All 11 selection tests passed
  in that opt-in run. No real account tokens or private messages were used.
- Native mnml Test UI verified label editing and Save, `@Work` filtering and
  Return selection, exact account/service chips, unavailable selection retention,
  and account assignment per space. A new space started with both accounts
  disabled; enabling Work there exposed only Work in its picker. Switching back
  preserved the original parked chat's restricted chip. A native scope capture
  is in ignored `build/connections/account-scope.png`.
- UI fixtures use an in-memory store only in a test profile with an explicit
  `MNML_CONNECTION_FIXTURE` file under the system temporary directory. Normal
  app runs continue to use Keychain. The disposable synthetic Keychain item
  used in initial UI setup was removed.
- No real Google or Notion OAuth consent or private account retrieval was
  performed. Real account validation is the next setup step for the user.

### Write implementation verification — 4 October 2026

- Added 42 write tests covering Google REST payloads, Notion hosted tool schemas,
  approval barriers, account/Space isolation, permission upgrades and rollback,
  changed-source refusal, partial creation, cancellation and one-attempt writes.
- Release regression run: 251 tests discovered, 248 passed, 3 opt-in live tests
  skipped, zero failures. Seven download lifecycle tests passed separately.
- Opt-in installed Antigravity CLI write check passed with synthetic credentials
  and mocked Sheets transport: exact typed preview, no mutation before native
  approval, one mock POST afterwards, and a cited result URL. No actual cloud
  accounts or files were changed by verification.
- Native mnml Test UI verified the write switches, Notion opt-in, review account
  identity and typed cell preview, Approve and Cancel actions, and disabled
  account/write controls in a new Space. The test profile used an in-memory
  fixture store and was closed after QA.
- Main app rebuilt and installed as 1.0.4, build `202610041721`. Strict code-signing
  verification passed; installed binary matched the packaged binary. Real Google
  permission consent and real Google/Notion writes still need user validation.
