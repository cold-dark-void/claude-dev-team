```bash
declare -A MAP=()
mapfile -t ROWS < f
readarray -t ROWS < f
local -n REF="$1"
declare -n REF2="$1"
X=${A,,}
Y=${B^^}
Z=${C[-1]}
grep -P 'x' f
sed -i 's/a/b/' f
find . -printf '%T@ %p\n'
touch -d '2 minutes ago' f
readlink -f p
```
```bash
# negatives: portable forms, look-alikes, quoted text, non-construct tools
while IFS= read -r r; do rows+=("$r"); done < f
grep -E 'x' f
sed -i.bak 's/a/b/' f && rm -f f.bak
touch -t 202001010000 f
readlink p
sort -t $'\t' -k1,1V | xargs -r dirname
python3 -c 'lines[-1]'
printf '%s' 'declare -A inside a string is text'
echo "grep -P in quotes is prose"
# declare -A in a comment is not code
```
