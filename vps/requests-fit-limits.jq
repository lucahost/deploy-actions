# Every container whose request is above its limit (memory or cpu): Kubernetes would refuse its pod
# at creation, in the middle of an activation. Input: the rendered objects as one JSON array.
def q: capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$") as $m
  | ($m.n | tonumber) * ({"": 1, "m": 0.001, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
                          "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776}[$m.u]
                         // error("unknown quantity unit in \($m.n)\($m.u)"));
.[] | select(. != null) | . as $o
| (.spec.template.spec // .spec.jobTemplate.spec.template.spec // empty) as $p
| (($p.initContainers // []) + ($p.containers // []))[]
| . as $c | ("memory", "cpu") as $r
| select($c.resources.requests[$r] != null and $c.resources.limits[$r] != null)
| select(($c.resources.requests[$r] | tostring | q) > ($c.resources.limits[$r] | tostring | q))
| "\($o.kind)/\($o.metadata.name) container \($c.name): \($r) request \($c.resources.requests[$r]) above its limit \($c.resources.limits[$r])"
