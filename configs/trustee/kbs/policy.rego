# Demo resource policy for the local RK3588/OpenCCA Trustee setup.
#
# This policy is intentionally permissive enough for the current prototype:
# KBS grants resources when AS returns non-sample CCA evidence. Production
# deployments should replace it with a policy that binds expected platform
# measurements, Realm measurements, workload identity, and resource path.

package policy

default allow = false

allow {
	not input["submods"]["cpu"]["ear.veraison.annotated-evidence"]["sample"]
}
