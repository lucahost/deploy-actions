{{/* The secure defaults every pod gets. Not values: vps.yaml can't change them. */}}
{{- define "vps.pod" -}}
automountServiceAccountToken: false
enableServiceLinks: false
hostUsers: false
securityContext:
  runAsNonRoot: true
  runAsUser: {{ .uid }}
  runAsGroup: {{ .gid | default .uid }}
  seccompProfile:
    type: RuntimeDefault
{{- end }}
{{- define "vps.container" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
{{- end }}
{{/* An image: built ones come from .Values.images (set by vps-app.yml), others are pinned in vps.yaml. */}}
{{- define "vps.image" -}}
{{- if .spec.build -}}
{{- $img := index .root.Values.images .key | default "" -}}
{{- if not $img }}{{ fail (printf "no built image for %s (vps-app.yml sets .images)" .key) }}{{ end -}}
{{- $img -}}
{{- else -}}
{{- .spec.image -}}
{{- end -}}
{{- end }}
{{- define "vps.env" -}}
{{- if or .env .secretEnv }}
{{- with .env }}
env:
{{- range $k, $v := . }}
  - name: {{ $k }}
    value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- with .secretEnv }}
envFrom:
{{- range . }}
  - secretRef:
      name: {{ . }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{/* PVC for a tenant volume: claim and PV names follow tenantgen's conventions. */}}
{{- define "vps.pvc" -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .claim }}
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled   # a revert or rollback leaves the claim (and the data) bound
spec:
  storageClassName: local-static
  accessModes: [ReadWriteOnce]
  volumeName: {{ .app }}-{{ .volume }}
  resources:
    requests:
      storage: 1Mi                                # the PV's capacity is the platform's (tenant entry)
{{- end }}
