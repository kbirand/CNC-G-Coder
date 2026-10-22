# Solder-Mask Pad Etching

How to open the pads in a cured solder mask so the bare copper shows, using the
same bit as the isolation. You never change the bit.

**You need:** one flat 0.5 mm end mill, used for both isolation and pad etching.

## Before you start

1. In the app, set both **Isolation** and **Mask etch** to the same bit: the
   flat 0.5 mm.
2. Set **Etch depth** (mask section) to **0**.
3. Clamp the board firmly. **It must not move until the very end.**

## Part 1: Copper

4. Home the machine.
5. Set **X0/Y0** on the board and probe **Z** there.
6. Put a small piece of tape over that X0/Y0 spot and press its edges down.
7. Probe the **height map**. Use 5 mm spacing for best results.
8. Run the **front isolation** with the height map on.

## Part 2: Solder mask

9. Apply the solder mask over the board, tape included. **Leave the board
   clamped.**
10. Cure it with UV light.
11. Peel off the tape and wipe that spot with isopropyl alcohol. You should see
    bare, clean copper at X0/Y0.

## Part 3: Open the pads

12. Press **Probe Z at origin**. The probe touches the bare spot and Z is exact
    again.
13. Send the **top mask etch** with the height map on.
14. When the program pauses for a tool change, **don't change the bit and don't
    probe**. Just press **Continue**.
15. The bit skims the copper and removes the mask from the pads.

## Check the result

- **Pads shiny copper:** done.
- **A thin layer of mask still on the pads:** run the mask etch again with Etch
  depth **−0.01**.

## Rules that matter

- **Never move or unclamp the board** between steps 3 and 15.
- **Never probe Z on top of the mask.** Only probe on the bare spot. Cured mask
  does not conduct, so the probe cannot sense the copper through it.
- **If the machine restarts or you re-home it,** repeat step 12 before cutting.

## Why it works

- **Z0 is the copper surface.** The isolation and the mask etch use the same
  bit and the same height map, so Etch depth 0 puts the bit right on the copper.
- **Copper is about 0.035 mm thick.** Small errors of ±0.01–0.02 mm only skim
  the copper or leave a thin film of mask, never cut through.
- **Why the tape.** The probe works by electrical contact. The taped spot stays
  free of mask, so step 12 can re-measure Z on bare copper. Any tape works if
  you wipe off its glue afterwards; Kapton just peels cleaner.
