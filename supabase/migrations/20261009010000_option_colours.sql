-- Stage 7 (Dad's decision at the 2b review): the fund colours are spread by
-- lightness, not just hue, so the options can be told apart without seeing colour
-- (colour-blind readers, or a printout in grey). Same hues, deeper shades; every
-- pair of option colours now differs by at least 1.4 : 1 (it was 1.19 : 1).
-- Savings (#E0A400) and GICs (#A82250, was #D6336C) live in the app's theme
-- (src/styles/theme.css and src/lib/colours.ts), which change with this migration.

update public.funds set colour = '#146DE4' where id = 'dow';        -- was #2F80ED
update public.funds set colour = '#F06008' where id = 'nasdaq100';  -- was #F76B15
update public.funds set colour = '#074945' where id = 'tsx';        -- was #0B6E69
