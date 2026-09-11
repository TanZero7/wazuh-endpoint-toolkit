"""
Batch-render PDF + DOCX for every kit's INTEGRATION-GUIDE.md and docs/*-PoC.md,
using the same content model / renderers as Suricata-Wazuh-Windows-Kit, driven
by md_parse.py instead of a hand-written content.py per kit.

Run from this directory: python build_all.py
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KITS_ROOT = os.path.dirname(HERE)

SKIP_DIRS = {"_doc-toolkit"}


def run(args):
    print("  $", " ".join(f'"{a}"' if " " in a else a for a in args))
    r = subprocess.run([sys.executable] + args, cwd=HERE)
    if r.returncode != 0:
        raise SystemExit(f"FAILED: {args}")


def main():
    kit_dirs = sorted(
        d for d in glob.glob(os.path.join(KITS_ROOT, "*"))
        if os.path.isdir(d) and os.path.basename(d) not in SKIP_DIRS
    )
    for kit_dir in kit_dirs:
        kit_name = os.path.basename(kit_dir)
        docs_dir = os.path.join(kit_dir, "docs")
        guide_md = os.path.join(kit_dir, "INTEGRATION-GUIDE.md")
        poc_candidates = glob.glob(os.path.join(docs_dir, "*-PoC.md"))

        if not os.path.isfile(guide_md) and not poc_candidates:
            print(f"-- {kit_name}: nothing to render, skipping")
            continue

        os.makedirs(docs_dir, exist_ok=True)

        # base name for output files: derive from the PoC filename if present,
        # else from the kit folder name
        if poc_candidates:
            poc_md = poc_candidates[0]
            base = os.path.basename(poc_md)[: -len("-PoC.md")]
        else:
            poc_md = None
            base = kit_name.replace("-Wazuh-Windows-Kit", "-Wazuh").replace("-Wazuh-Kit", "-Wazuh")

        print(f"\n=== {kit_name}  (base: {base}) ===")

        if poc_md:
            run(["build_docx.py", os.path.join(docs_dir, f"{base}-PoC.docx"), poc_md, "PROOF OF CONCEPT"])
            run(["build_pdf.py", os.path.join(docs_dir, f"{base}-PoC.pdf"), poc_md, "PROOF OF CONCEPT"])
        else:
            print("  (no docs/*-PoC.md found, skipping PoC doc)")

        if os.path.isfile(guide_md):
            run(["build_docx.py", os.path.join(docs_dir, f"{base}-Integration-Guide.docx"), guide_md, "INTEGRATION GUIDE"])
            run(["build_pdf.py", os.path.join(docs_dir, f"{base}-Integration-Guide.pdf"), guide_md, "INTEGRATION GUIDE"])
        else:
            print("  (no INTEGRATION-GUIDE.md found, skipping guide doc)")

    print("\nAll done.")


if __name__ == "__main__":
    main()
