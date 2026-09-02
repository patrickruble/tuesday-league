-- ============================================================
--  PATCH 014 — scorecard upload path
--  Apply after patch-013.
--
--  The original policy expected
--      scorecards/{season}/wk{n}/{match}/{team}/{ts}.jpg
--  and looked for the team id at the fifth folder. Every other
--  bucket puts the owner first, which is simpler to reason
--  about and harder to get wrong:
--      scorecards/{team}/w{week}/{match}/{ts}.jpg
--
--  Week and match are still in the path, so pulling a season
--  out of the archive is still a matter of filtering on it.
-- ============================================================

drop policy if exists "upload own scorecards" on storage.objects;
drop policy if exists "read scorecards"       on storage.objects;

create policy "upload own scorecards"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'scorecards'
    and (storage.foldername(name))[1] = my_team()::text
  );

create policy "replace own scorecards"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'scorecards'
    and (storage.foldername(name))[1] = my_team()::text
  );

-- Anyone signed in can look at a card. The opponent has to be
-- able to check it, and the archive is meant to be browsable.
create policy "read scorecards"
  on storage.objects for select to authenticated
  using (bucket_id = 'scorecards');

-- Still no delete policy anywhere. Photos are evidence.
