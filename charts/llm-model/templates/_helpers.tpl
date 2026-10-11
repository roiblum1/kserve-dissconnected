{{- define "model.keySecret" -}}
{{- .Values.internalKey.existingSecret | default (printf "%s-internal-key" .Values.model.name) -}}
{{- end -}}
{{- define "model.validate" -}}
{{- if not (has .Values.route.through (list "scheduler" "service")) -}}
{{- fail "route.through must be scheduler or service" -}}
{{- end -}}
{{- if and (not .Values.route.direct) (not .Values.peer.enabled) -}}
{{- fail "route.direct=false needs peer.enabled=true: the model would have no route at all" -}}
{{- end -}}
{{- if and .Values.route.direct (eq .Values.route.through "scheduler") (not .Values.model.scheduler) -}}
{{- fail "route.through=scheduler needs model.scheduler=true" -}}
{{- end -}}
{{- if and .Values.peer.enabled (not .Values.model.scheduler) -}}
{{- fail "peer.enabled needs model.scheduler=true: the serving route sends to the model's InferencePool" -}}
{{- end -}}
{{- if and .Values.model.scheduler .Values.route.direct (not .Values.internalKey.value) (not .Values.internalKey.existingSecret) -}}
{{- fail "set internalKey.value or internalKey.existingSecret: without it KServe's own route lets tenants use the model uncounted" -}}
{{- end -}}
{{- end -}}
{{- define "model.pool" -}}
{{- printf "%s-inference-pool" .Values.model.name -}}
{{- end -}}
{{- define "model.vllmArgs" -}}
{{- $args := .Values.model.args -}}
{{- with .Values.model.maxModelLen -}}
{{- $args = printf "%s --max-model-len %v" $args . -}}
{{- end -}}
{{- $args | trim -}}
{{- end -}}
