# K8s Deployment & Validation Workflow

1. **Plan Phase:** `@architect` erstellt den Architekturplan (`.opencode/plans/`).
2. **Plan Audit:** `@security-audit` verifiziert die Kustomize-Hierarchie und Storage-Wahl.
3. **Build Phase:** `@k8s-specialist` generiert die YAML-Ressourcen.
4. **Integration Test:** `@integration-test` führt Kustomize-Builds und Server-Side Dry-Runs gegen den Cluster aus.
5. **Correction Loop:** Schlägt Phase 4 fehl, korrigiert `@k8s-specialist` den Code basierend auf den Terminal-Fehlermeldungen. Phase 4 und 5 wiederholen sich bis zum Status `PASS`.
6. **Final Audit:** `@security-audit` führt einen isolierten Check auf SOPS-Verschlüsselung und SecurityContexts der finalen Files durch.
7. **Commit Preparation:** Zusammenfassung der Änderungen.