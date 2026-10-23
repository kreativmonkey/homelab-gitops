#!/usr/bin/env python3
"""Fill missing Audiobookshelf author images.

1. Author ASIN from Audnexus book data (book ASIN from the item folder
   "[ASIN]" or metadata) -> ABS /authors/:id/match {asin, region: de}.
   ABS' own lookup defaults to region "us" and searches by name only.
2. Still no image: Wikidata person (human + writer-like occupation, exact
   label match) with an image (P18) -> ABS /authors/:id/image {url}.
Translator pseudo-authors ("... - Übersetzer") are skipped.

Env: ABS_URL, ABS_TOKEN, ABS_LIBRARY (id), DRY=1 for a dry run,
SKIP_WIKIDATA="Name A,Name B" for extra names with unconfirmed matches.
Usually run via libation-import.sh, which provides the token.
"""
import json, os, re, sys, unicodedata, urllib.error, urllib.parse, urllib.request

ABS = os.environ["ABS_URL"].rstrip("/")
TOKEN = os.environ["ABS_TOKEN"]
LIB = os.environ["ABS_LIBRARY"]
DRY = os.environ.get("DRY") == "1"
# Names whose Wikidata hit could not be confirmed as the same person
# David Gromer: credited as Hörspiel adaptor; not confirmed to be the director/presenter on Wikidata
SKIP_WIKIDATA = {"David Gromer"} | {
    n.strip() for n in os.environ.get("SKIP_WIKIDATA", "").split(",") if n.strip()}
UA = "homelab-abs-author-images/1.0 (https://github.com/kreativmonkey/homelab-gitops)"

# writer, author, novelist, children's writer, poet, screenwriter, journalist,
# essayist, columnist, translator, comedian, cabaret artist, psychologist,
# family therapist, pedagogue, illustrator, philosopher, playwright, blogger,
# non-fiction writer, scientist, physician, psychotherapist
OCCUPATIONS = {
    "Q36180", "Q482980", "Q6625963", "Q4853732", "Q49757", "Q28389", "Q1930187",
    "Q11774202", "Q1086863", "Q333634", "Q245068", "Q15296811", "Q212980",
    "Q1350189", "Q1231865", "Q644687", "Q4964182", "Q214917", "Q8246794",
    "Q15980158", "Q901", "Q39631", "Q2640827", "Q18814623", "Q2259451",
}


def http(url, data=None, method=None, headers=None, timeout=30):
    h = {"User-Agent": UA, **(headers or {})}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw[:1] in (b"{", b"[") else raw.decode()


def abs_api(path, data=None, method=None):
    return http(f"{ABS}/api{path}", data, method, {"Authorization": f"Bearer {TOKEN}"})


def norm(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z]", "", s)


def book_asins(author_id):
    a = abs_api(f"/authors/{author_id}?include=items")
    out = []
    for it in a.get("libraryItems", []):
        m = re.search(r"\[([0-9A-Z]{10})\]", it.get("relPath", "") or it.get("path", ""))
        asin = (m and m.group(1)) or it["media"]["metadata"].get("asin")
        if asin:
            out.append(asin)
    return out


def audnexus_author_asin(name, asins):
    for asin in asins:
        try:
            b = http(f"https://api.audnex.us/books/{asin}?region=de")
        except Exception:
            continue
        for au in b.get("authors", []):
            if au.get("asin") and norm(au["name"]) == norm(name):
                return au["asin"]
    return None


def wikidata_image(name):
    q = urllib.parse.urlencode({"action": "wbsearchentities", "search": name, "language": "de",
                                "type": "item", "limit": 5, "format": "json"})
    hits = http(f"https://www.wikidata.org/w/api.php?{q}").get("search", [])
    for h in hits:
        if norm(h.get("label", "")) != norm(name):
            continue
        e = http(f"https://www.wikidata.org/wiki/Special:EntityData/{h['id']}.json")["entities"][h["id"]]
        c = e.get("claims", {})
        ids = lambda p: {x["mainsnak"].get("datavalue", {}).get("value", {}).get("id") for x in c.get(p, [])}
        if "Q5" not in ids("P31") or not (ids("P106") & OCCUPATIONS) or "P18" not in c:
            continue
        f = c["P18"][0]["mainsnak"]["datavalue"]["value"]
        desc = e.get("descriptions", {}).get("de", e.get("descriptions", {}).get("en", {})).get("value", "")
        return f"{h['id']} ({desc})", "https://commons.wikimedia.org/wiki/Special:FilePath/" + urllib.parse.quote(f.replace(" ", "_")) + "?width=600"
    return None, None


def main():
    authors = abs_api(f"/libraries/{LIB}/authors")["authors"]
    todo = [a for a in authors if not a.get("imagePath")]
    print(f"{len(authors)} authors, {len(todo)} without image{' (DRY)' if DRY else ''}")
    for a in sorted(todo, key=lambda x: x["name"]):
        try:
            handle(a)
        except Exception as ex:
            print(f"FAIL        {a['name']}: {ex}")


def handle(a):
        name = a["name"]
        if re.search(r"(übersetzer|translator|sprecher|herausgeber)", name, re.I):
            print(f"SKIP role   {name}")
            return
        asin = a.get("asin") or audnexus_author_asin(name, book_asins(a["id"]))
        if asin:
            if DRY:
                print(f"AUDNEXUS?   {name} ({asin})")
            else:
                try:
                    r = abs_api(f"/authors/{a['id']}/match", {"asin": asin, "region": "de"}, "POST")
                except urllib.error.HTTPError:
                    r = {}  # ASIN unknown to Audnexus
                if r.get("author", {}).get("imagePath"):
                    print(f"AUDNEXUS ok {name} ({asin})")
                    return
        if name in SKIP_WIKIDATA:
            print(f"NONE        {name} (wikidata ambiguous, skipped)")
            return
        qid, url = wikidata_image(name)
        if not url:
            print(f"NONE        {name}" + (f" (asin {asin}, no image)" if asin else ""))
            return
        if DRY:
            print(f"WIKIDATA?   {name} {qid} {url}")
            return
        try:
            abs_api(f"/authors/{a['id']}/image", {"url": url}, "POST")
            print(f"WIKIDATA ok {name} {qid}")
        except Exception as ex:
            print(f"FAIL        {name} {qid}: {ex}")


if __name__ == "__main__":
    sys.exit(main())
