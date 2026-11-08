# Moving every Mobitech DCON call off the NUC

**The rule (owner, 2026-09-24):** the NUC runs the Home Assistant bridge and
nothing else. Every Mobitech DCON call, the eight report reads *and* the valve
run/stop commands, belongs in Firebase Cloud Functions.

**Why it is not done yet:** Mobitech's servers sit behind an AWS load
balancer that answers every Google Cloud address with `403 Forbidden`. It was
re-probed on 2026-09-24 from asia-southeast1, us-central1 and europe-west1
with four header shapes (Python default, a browser, a browser with Origin and
Referer, okhttp): all `403 awselb/2.0`. The same requests from a home
connection get 200. It is an address block, so no code change inside a
function gets through. The fix is one fixed outgoing IP for the functions,
allowlisted by Mobitech.

## Where things stand

| Piece | State |
|---|---|
| `irrigation_report` function | Deployed. Still `DCON_TRANSPORT=relay` (the NUC fetches). Routes through `DCON_VPC_CONNECTOR` the moment that is set in `functions/.env`. |
| `irrigation_command` function | **Deployed and dormant.** Does nothing, not even a delete, until `meta/irrigationControl/enabled` is `true`. The NUC still consumes `irrigation_commands`. |
| Secrets | `DCON_TOKEN_ID`, `DCON_SERIAL`, `DCON_COMMAND_AUTH`, `DCON_DEVICE_ID` in Secret Manager (the last two copied from the add-on options through a pipe, never printed). |
| iOS | 0.3.1 opens valve control when `meta/irrigationControl.enabled` is true, with no bridge needed. |
| Static egress IP | **Not created.** Needs the Google Cloud steps below. |
| Mobitech allowlist | **Not requested.** Needs the IP first. |

## 1. Google Cloud: one fixed outgoing IP (owner, about 10 minutes)

In the Cloud Console for project `snof-live`, region **asia-southeast1**:

1. **APIs & Services → Enable**: *Serverless VPC Access API* and *Compute
   Engine API*.
2. **VPC network → IP addresses → Reserve external static IP address**. Name
   `dcon-egress-ip`, type *Regional*, region `asia-southeast1`. Note the
   address.
3. **VPC network → Serverless VPC access → Create connector**. Name
   `dcon-egress`, region `asia-southeast1`, network `default`, subnet *Custom
   IP range* `10.8.0.0/28`, min instances 2, max 3, instance type `e2-micro`.
4. **Network services → Cloud NAT → Create**. Name `dcon-nat`, network
   `default`, region `asia-southeast1`, Cloud Router *create new* `dcon-router`,
   source *all subnets' primary and secondary ranges*, NAT IP addresses
   *Manual* → `dcon-egress-ip`.

Cost, roughly: the connector's two e2-micro instances about US$12/month, the
static IP about US$3/month while in use, the NAT gateway about US$1/month;
about US$16/month in all. Function calls themselves stay in the free tier.

Then in `dashboard/functions/.env` (per machine, gitignored):

```
DCON_VPC_CONNECTOR=projects/snof-live/locations/asia-southeast1/connectors/dcon-egress
```

and `firebase deploy --only functions:reports`. Both functions now leave
Google through `dcon-egress-ip`.

## 2. Ask Mobitech to allowlist it

> Subject: API access allowlist for our DCON controller
>
> Hello Mobitech team,
>
> We read our DCON irrigation controller's data (dashboard, logs, reports)
> and send manual run/stop commands through dcon.mobitechwireless.com
> (`/v1/http/` and `/v1/command/`) from our own server. Requests from our
> server's address are refused with HTTP 403 by your load balancer, while the
> same requests from a home connection succeed.
>
> Could you allowlist this single static IP address for API access:
> **<dcon-egress-ip>**
>
> Account / controller: <owner's Mobitech login and controller name>
>
> Thank you,
> <name>

## The one extra thing on the relay: web Mobitech sign-in

Owner's exception (2026-11-01): the web dashboard signs SNOF in to Mobitech
through the `mobitech_session` function, which sends `otp`, `login` and `prove`
through the relay (add-on 0.10.10, `bridge/relay.py` `SIGNIN_CALLS`). At
cut-over it moves with the reports: `DCON_TRANSPORT=direct` makes it call
Mobitech itself (`dcon.DirectTransport` spells the same three calls), and
step d below removes the relay with nothing left to carry.

## The second extra: more reads, and starting a program

Owner's decision (2026-11-08, option A, branch `mobitech-more`, add-on 0.11.0):
the new Mobitech features go through the same NUC path, a **second documented
exception** to "no new DCON code in the add-on", with strict named allow-lists
and no new polling loops (reads happen on page open and Refresh only):

- `bridge/relay.py` gains five named reads: `programs`, `electricity_day`,
  `pressure_day` (arg `date`), `rain` (the weather API, `device_id` from the
  add-on options) and `cmd_status` (arg `trans_id`, 10 digits; used by the
  consumer while confirming). Every answer is cut down on the NUC
  (`reduce_read`): no `users`, `sim`, packets 1/4/5/8, no free-text `data`,
  no serial/device/user ids, and any run of ten digits is removed.
- `bridge/irrigation_control.py` gains `program` (`ET01-NNN-HH MM@slot`) and
  moves run/stop to `V…ON` / `MOFF`; option `allow_program_start`.

**What moves at cut-over:** the Function side already has the twins
(`dcon.DirectTransport` spells the five reads and `rain`; the dormant
`irrigation_control.py` has the same program/run/stop logic), so cut-over is
the same switch as before (`DCON_TRANSPORT=direct`, then the consumer swap in
step b), and the add-on loses these with the rest. `DCON_DEVICE_ID` becomes a
secret of the report function too (the rain call needs it).

## 3. Cut over (same day the allowlist works)

Do these in order. Step 3b is the one that must never be reversed in order:
two consumers on `irrigation_commands` would send a valve command twice.

a. **Reports.** Set `DCON_TRANSPORT=direct` in `functions/.env`, deploy
   `functions:reports`, press Generate on *Controller dashboard*. It must come
   back **Ready**. A `DCON dashboard: HTTP 403` card means the allowlist is not
   live yet: put `relay` back and wait.

b. **Valve control, NUC off first.** Merge `allow_irrigation_control: false`
   into the add-on options (never POST a partial options object) and restart.
   The log must say `Irrigation control is off; not watching the irrigation
   queue`. Only then:

   ```
   firebase database:set /farms/snof/meta/irrigationControl \
     '{"enabled": true, "maxMinutes": 60}' --project snof-live
   ```

   First press with someone at the pump house. The result node carries
   `"runtime": "cloud-functions"`. Kill switch: set `enabled` to `false`.

c. **Strip DCON from the add-on.** Delete `bridge/relay.py`,
   `bridge/irrigation_control.py` and every `dcon_*`,
   `allow_irrigation_control` and `irrigation_max_minutes` option and schema
   line; bump the version; clear those keys from the Supervisor options *in
   the same merge that drops them*, or the add-on refuses to start; deploy;
   verify inside the container.

d. **Remove the relay.** Delete `RelayTransport` from `functions/dcon.py`,
   make `direct` the only transport, and remove the `/relay` handling from
   the RTDB rules and docs.
