--liquibase formatted sql

--changeset KarinaMasihHudson:C78AE0C4 stripComments:false runOnChange:true splitStatements:false

/* =============================================
      Author : Karina Masih-Hudson
 Create Date : 2021-03-02
 Description : Align Tracfone Program tiers
       Usage : EXEC [Tracfone].[P_ProcessProgramTierAlignment]
 KMH20211109 : Added program logic for VIP/VIP+ TER accounts
			 : TierCodes like 'T1E%' or 'T1X%' added to ProgramID 20 & 24 (TER Handsets/TER Accessories)
			 : TierCodes NOT like 'T1E%' or 'T1X%' added to ProgramID 18 & 21 (Handsets/Accessories)
 KMH20211203 : Added an exlcusion of test accounts 135944, 13379 to #Account insertion so they do not follow process
 KMH20220927 : Updating process for TBV
				- If TF Tier T1E then insert into Program ID 36/Tier ID 40
			   Wrote code but commented out for now (search KMH20220927:FUTURE to find)
			    - Delete from Program ID 4/Tier ID 4 if TF Tier T1E
				- Remove T1E from update/insert into TER Accessories (Program ID 24/Tier ID 25)
				- Update or Insert T1E accounts into Alphacomm Accessories (Program ID 37/Tier ID 41)
 KMH20221010 : Updated PK insert issue into AccountProgram
 MR20230104  : Added in Karina's commented out code from 09/27/22.
			 : Added two sections of "AND NOT EXISTS" for TBV tagged accounts to not be added or switched to
             Tier ID 4 (Activations).
				They should remain Tier ID 14 (Airtime).
 MR20230106  : Added in logging to the Account.tblAccountProgramHistory table.
			 : Added in #TBVaccountTiers section to include a list of tiers for TBV accounts.
			 : Removed two of the "FUTURE" sections from 09/27 of update/inserts that were now handled in the new #TBV section.
			 : Implemented the commented out code from 09/27 "Removed T1E from update/insert into
             TER Accessories (Program ID 24/Tier ID 25)"
 KMH20240219 : Removed Amazon, Apple gift card programs
 ============================================= */
CREATE OR ALTER PROCEDURE [Tracfone].[P_ProcessProgramTierAlignment]
    (@FileId INT)
AS

------Testing
--DECLARE @FileId INT = 69668

BEGIN TRY
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF OBJECT_ID('tempdb..#Account') IS NOT NULL
        BEGIN
            DROP TABLE #Account
        END

    CREATE TABLE #Account
    (
        Account_ID BIGINT
        , TierCode NVARCHAR(10)
    )

    INSERT INTO #Account
    SELECT DISTINCT
        COALESCE(das.TSP_ID, amt.AccountId) AS Account_ID
        , CASE
            WHEN das.TIER IS NULL THEN CAST(amt.TierCode AS NVARCHAR(10))
            ELSE CAST(das.TIER AS NVARCHAR(10))
        END AS TierCode
    FROM
        Tracfone.tblTracTSPAccountRegistration AS tar
    LEFT JOIN Tracfone.tblDealerApprovedSignUp AS das
        ON CAST(das.TSP_ID AS VARCHAR(20)) = tar.Account_ID AND das.FileId = @FileID
    LEFT JOIN Tracfone.tblAirtimeMarginTier AS amt
        ON CAST(amt.AccountId AS VARCHAR(20)) = tar.Account_ID AND amt.FileId = @FileID
    WHERE
        tar.TracfoneStatus IN (1, 2, 4, 5)
        AND tar.Account_ID NOT IN ('135944', '13379')		--KMH20211203


    IF OBJECT_ID('tempdb..#ApprovedAccounts') IS NOT NULL
        BEGIN
            DROP TABLE #ApprovedAccounts;
        END;

    CREATE TABLE #ApprovedAccounts
    (
        Account_ID VARCHAR(20)
        , TracfoneStatus TINYINT
        , TracfoneTierID TINYINT
        , TierCode NVARCHAR(10)
    )

    INSERT INTO #ApprovedAccounts
    SELECT
        tar.Account_ID
        , tar.TracfoneStatus
        , tar.TracfoneTierId
        , a.TierCode
    FROM
        #Account AS a
    JOIN Tracfone.tblTracTSPAccountRegistration AS tar ON tar.Account_ID = CAST(a.Account_ID AS VARCHAR(20))
    JOIN dbo.Account AS a2 ON CAST(a2.Account_ID AS VARCHAR(20)) = tar.Account_ID
    WHERE
        tar.TracfoneStatus IN (1, 2, 4, 5)


    DROP TABLE IF EXISTS #HistoryInsert

    CREATE TABLE #HistoryInsert
    (
        Account_ID INT NULL,
        CreateDate DATETIME NULL,
        AddAction VARCHAR(20) NULL,
        UserID VARCHAR(20) NULL,
        AddTierID TINYINT NULL,
        RemoveAction VARCHAR(20) NULL,
        RemovedTierID TINYINT NULL
    );

    /* All accounts in approved, pending, new, or pending review (1,2,4,5) are put in activations tier
    Silver and above gets activation, Bronze does not get activation. (Except those in TBV - as of 01/01/2023) */
    --Activation
    INSERT INTO Account.tblAccountProgram
    (
        AccountID
        , ProgramID
        , TierID
    )
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID)		--MR20230106
    SELECT
        a.Account_ID
        , 4 AS ProgramID
        , 4 AS TierID
    FROM
        #ApprovedAccounts AS a
    WHERE
        a.TracfoneTierId <> 4
        AND a.Account_ID NOT IN
        (
            SELECT a.Account_ID
            FROM Account.tblAccountProgram AS ap
            JOIN #ApprovedAccounts AS a
                ON a.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
            WHERE
                ap.ProgramID = 4
        )
        AND NOT EXISTS (
            SELECT 1 FROM Account.tblTags AS t					--MR20230104
            WHERE
                a.Account_ID = CAST(t.SubjectId AS VARCHAR(20))
                AND t.Tag LIKE 'TBV'
        )

    /* If account is Bronze (4) tier, then airtime only */
    UPDATE ap
    SET ap.TierID = 14
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        'Remove',
        Deleted.TierID
    --MR20230106
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID, RemoveAction, RemovedTierID)
    --Select *
    FROM Account.tblAccountProgram AS ap
    WHERE
        ProgramID = 4
        AND TierID = 4
        AND ap.AccountID IN (SELECT a.Account_ID FROM #ApprovedAccounts AS a WHERE a.TracfoneTierId = 4)

    /* If account is in the program but their status is in 1,2,4,5 (changed) and they were in airtime, update
    to activation - except Bronze
    MR20230104: and except those with tag TBV. These TBV accounts all entered as Airtime rather than Activations.*/
    UPDATE ap
    SET ap.TierID = 4
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        'Remove',
        Deleted.TierID
    --MR20230106
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID, RemoveAction, RemovedTierID)
    --Select *
    FROM Account.tblAccountProgram AS ap
    JOIN #ApprovedAccounts AS a ON a.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ap.ProgramID = 4 AND ap.TierID = 14 AND a.TracfoneStatus IN (1, 2, 4, 5) AND a.TracfoneTierId <> 4
        AND NOT EXISTS (
            SELECT 1 FROM Account.tblTags AS t					--MR20230104
            WHERE
                a.Account_ID = CAST(t.SubjectId AS VARCHAR(20))
                AND t.Tag LIKE 'TBV'
        )

    /* If account is in the program but their status is NOT in 1,2,4,5 (changed) and they were in
    activation, update to airtime */
    UPDATE ap
    SET ap.TierID = 14
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        'Remove',
        Deleted.TierID
    --MR20230106
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID, RemoveAction, RemovedTierID)
    --Select *
    FROM Account.tblAccountProgram AS ap
    JOIN #ApprovedAccounts AS a ON a.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ProgramID = 4
        AND TierID = 4
        AND ap.AccountID NOT IN
        (
            SELECT a.Account_ID
            FROM #ApprovedAccounts AS a
            WHERE a.TracfoneTierId = 4 OR a.TracfoneStatus IN (1, 2, 4, 5)
        )

    /* If account is in the program but their tag is TFRural, CStore, or Classwallet and they were in airtime,
    then update to activation */
    UPDATE ap
    SET TierID = 4
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        'Remove',
        Deleted.TierID
    --MR20230106
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID, RemoveAction, RemovedTierID)
    --Select *
    FROM
        Account.tblAccountProgram AS ap
    JOIN #ApprovedAccounts AS a ON a.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ProgramID = 4
        AND TierID = 14
        AND AccountID IN
        (
            SELECT SubjectId FROM Account.tblTags WHERE Tag IN ('TFRURAL', 'CSTORE', 'ClassWallet')
        )


    /* KMH20220927: If account is tagged 'TBV' then Program ID 36/Tier ID 40
    On 1/1/2023 they may have to be dropped from Program ID 4/Tier ID 4 - commented out for now.
    MR20230106: Added this section to include other tiers that TBV accounts need to have*/


    DROP TABLE IF EXISTS #TBVtiers
    CREATE TABLE #TBVtiers
    (
        ProgramID INT,
        TierID INT
    );
    INSERT INTO #TBVtiers
    VALUES
    (4, 14),
    (6, 6),
    (20, 21),
    (33, 37),
    (36, 40),
    (37, 41);	--KMH20240219

    DROP TABLE IF EXISTS #TBVaccounts

    SELECT aa.Account_ID
    INTO #TBVaccounts
    FROM #ApprovedAccounts AS aa
    JOIN Account.tblTags AS t
        ON
            aa.Account_ID = CAST(t.SubjectId AS VARCHAR(20))
            AND t.Tag LIKE 'TBV'

    DROP TABLE IF EXISTS #TBVaccountTiers

    SELECT
        t.Account_ID,
        tr.ProgramID,
        tr.TierID
    INTO #TBVaccountTiers
    FROM #TBVaccounts AS t, #TBVtiers AS tr


    ------Removing those that already match
    DELETE tbv
    FROM #TBVaccountTiers AS tbv
    JOIN account.tblAccountProgram AS p
        ON
            tbv.Account_ID = p.AccountID
            AND tbv.ProgramID = p.ProgramID
            AND tbv.TierID = p.TierID

    /*Updating the TierId if the program ID matches and inserting a new TierID if not.*/

    MERGE Account.tblAccountProgram AS ap
    USING #TBVaccountTiers AS tbv
        ON
            tbv.Account_ID = ap.AccountID
            AND tbv.ProgramID = ap.ProgramID
    WHEN MATCHED
        THEN
        UPDATE SET ap.TierID = tbv.TierID
    WHEN NOT MATCHED BY TARGET
        THEN
        INSERT (AccountID, ProgramID, TierID)
        VALUES (tbv.Account_ID, tbv.ProgramID, tbv.TierID)
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        CASE
            WHEN $action = 'UPDATE' THEN 'Remove'
            ELSE NULL
        END,
        CASE
            WHEN $action = 'UPDATE' THEN Deleted.TierID
            ELSE NULL
        END
    INTO #HistoryInsert (
        Account_ID,
        CreateDate,
        AddAction,
        UserID,
        AddTierID,
        RemoveAction,
        RemovedTierID
    );


    /* KMH20211109: If account is VIP/VIP+ then add to Program ID 20 (Unlocked Handsets TER) and 24 (TER Accessories)
    Else add to Program ID 18 (Unlocked Handsets) and 21 (Accessories) */
    IF OBJECT_ID('tempdb..#Handsets') IS NOT NULL
        BEGIN
            DROP TABLE #Handsets
        END

    SELECT aa.Account_ID, aa.TierCode, ap.ProgramID, ap.TierID
    INTO #Handsets
    FROM #ApprovedAccounts AS aa
    JOIN Account.tblAccountProgram AS ap
        ON aa.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ap.ProgramID IN (18, 20)
        AND (
            aa.Account_ID IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 18)
            AND aa.Account_ID IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 20)
        )

    DELETE ap
    OUTPUT
        Deleted.AccountID,
        GETDATE(),
        'TierAlignmentProc',
        'Remove',
        Deleted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, UserID, RemoveAction, RemovedTierID)		--MR20230106
    --SELECT ap.*,h.TierCode
    FROM Account.tblAccountProgram AS ap
    JOIN #Handsets AS h
        ON
            h.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
            AND h.ProgramID = ap.ProgramID
            AND h.TierID = ap.TierID
    WHERE
        (h.TierCode LIKE 'T1E%' OR h.TierCode LIKE 'T1X%')
        AND ap.ProgramID = 18
        AND ap.TierID = 20


    DELETE ap
    OUTPUT
        Deleted.AccountID,
        GETDATE(),
        'TierAlignmentProc',
        'Remove',
        Deleted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, UserID, RemoveAction, RemovedTierID)	--MR20230106
    --SELECT ap.*,h.TierCode
    FROM Account.tblAccountProgram AS ap
    JOIN #Handsets AS h
        ON
            h.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
            AND h.ProgramID = ap.ProgramID
            AND h.TierID = ap.TierID
    WHERE
        (h.TierCode NOT LIKE 'T1E%' AND h.TierCode NOT LIKE 'T1X%')
        AND ap.ProgramID = 20
        AND ap.TierID = 21


    IF OBJECT_ID('tempdb..#Accessories') IS NOT NULL
        BEGIN
            DROP TABLE #Accessories
        END

    SELECT aa.Account_ID, aa.TierCode, ap.ProgramID, ap.TierID
    INTO #Accessories
    FROM #ApprovedAccounts AS aa
    JOIN Account.tblAccountProgram AS ap
        ON aa.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ap.ProgramID IN (21, 24)
        AND (
            aa.Account_ID IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 21)
            AND aa.Account_ID IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 24)
        )

    DELETE ap
    OUTPUT
        Deleted.AccountID,
        GETDATE(),
        'TierAlignmentProc',
        'Remove',
        Deleted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, UserID, RemoveAction, RemovedTierID)			--MR20230106
    --SELECT ap.*,h.TierCode
    FROM Account.tblAccountProgram AS ap
    JOIN #Accessories AS h
        ON
            h.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
            AND h.ProgramID = ap.ProgramID
            AND h.TierID = ap.TierID
    WHERE
        (h.TierCode LIKE 'T1E%' OR h.TierCode LIKE 'T1X%')
        AND ap.ProgramID = 21
        AND ap.TierID = 22

    DELETE ap
    OUTPUT
        Deleted.AccountID,
        GETDATE(),
        'TierAlignmentProc',
        'Remove',
        Deleted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, UserID, RemoveAction, RemovedTierID)			--MR20230106
    --SELECT ap.*,h.TierCode
    FROM Account.tblAccountProgram AS ap
    JOIN #Accessories AS h
        ON
            h.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
            AND h.ProgramID = ap.ProgramID
            AND h.TierID = ap.TierID
    WHERE
        (h.TierCode NOT LIKE 'T1E%' AND h.TierCode NOT LIKE 'T1X%')
        AND ap.ProgramID = 24
        AND ap.TierID = 25


    /* VIP/VIP+ Accounts*/
    UPDATE Account.tblAccountProgram
    SET
        ProgramID = 20
        , TierID = 21
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        'Remove',
        Deleted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID, RemoveAction, RemovedTierID)	--MR20230106
    --	SELECT *
    FROM #ApprovedAccounts AS aa
    JOIN Account.tblAccountProgram AS ap
        ON aa.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ap.ProgramID = 18
        AND ap.TierID = 20
        AND (
            aa.TierCode LIKE 'T1E%'
            OR aa.TierCode LIKE 'T1X%'
        )
        AND aa.Account_ID NOT IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 20 AND TierID = 21)


    INSERT INTO Account.tblAccountProgram (AccountID, ProgramID, TierID)
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID)	--MR20230106
    SELECT DISTINCT
        aa.Account_ID
        , 20 AS ProgramID
        , 21 AS TierID
    FROM #ApprovedAccounts AS aa
    WHERE (
        aa.TierCode LIKE 'T1E%'
        OR aa.TierCode LIKE 'T1X%'
    )
    AND aa.Account_ID NOT IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 20 AND TierID = 21)


    UPDATE Account.tblAccountProgram
    SET
        ProgramID = 24
        , TierID = 25
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        'Remove',
        Deleted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID, RemoveAction, RemovedTierID)	--MR20230106
    --	SELECT *
    FROM #ApprovedAccounts AS aa
    JOIN Account.tblAccountProgram AS ap
        ON aa.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ap.ProgramID = 21
        AND ap.TierID = 22
        AND aa.TierCode LIKE 'T1X%'
        AND aa.Account_ID NOT IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 24 AND TierID = 25)



    INSERT INTO Account.tblAccountProgram (AccountID, ProgramID, TierID)
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID)	--MR20230106
    SELECT DISTINCT
        aa.Account_ID
        , 24 AS ProgramID
        , 25 AS TierID
    FROM #ApprovedAccounts AS aa
    WHERE
        aa.TierCode LIKE 'T1X%'
        AND aa.Account_ID NOT IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 24 AND TierID = 25)


    --/* Non-VIP/VIP+ Accounts*/
    UPDATE Account.tblAccountProgram
    SET
        ProgramID = 18
        , TierID = 20
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        'Remove',
        Deleted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID, RemoveAction, RemovedTierID)	--MR20230106
    --SELECT *
    FROM #ApprovedAccounts AS aa
    JOIN Account.tblAccountProgram AS ap
        ON aa.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ap.ProgramID = 20
        AND ap.TierID = 21
        AND (
            aa.TierCode NOT LIKE 'T1E%'
            AND aa.TierCode NOT LIKE 'T1X%'
        )
        AND aa.Account_ID NOT IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 18 AND TierID = 20)



    INSERT INTO Account.tblAccountProgram (AccountID, ProgramID, TierID)
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID)	--MR20230106
    SELECT DISTINCT
        aa.Account_ID
        , 18 AS ProgramID
        , 20 AS TierID
    FROM #ApprovedAccounts AS aa
    WHERE (
        aa.TierCode NOT LIKE 'T1E%'
        AND aa.TierCode NOT LIKE 'T1X%'
    )
    AND aa.Account_ID NOT IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 18 AND TierID = 20)


    UPDATE Account.tblAccountProgram
    SET
        ProgramID = 21
        , TierID = 22
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID,
        'Remove',
        Deleted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID, RemoveAction, RemovedTierID)	--MR20230106
    --SELECT *
    FROM #ApprovedAccounts AS aa
    JOIN Account.tblAccountProgram AS ap
        ON aa.Account_ID = CAST(ap.AccountID AS VARCHAR(20))
    WHERE
        ap.ProgramID = 24
        AND ap.TierID = 25
        AND (
            aa.TierCode NOT LIKE 'T1E%'
            AND aa.TierCode NOT LIKE 'T1X%'
        )
        AND aa.Account_ID NOT IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 21 AND TierID = 22)

    INSERT INTO Account.tblAccountProgram (AccountID, ProgramID, TierID)
    OUTPUT
        Inserted.AccountID,
        GETDATE(),
        'Add',
        'TierAlignmentProc',
        Inserted.TierID
    INTO #HistoryInsert (Account_ID, CreateDate, AddAction, UserID, AddTierID)		--MR20230106
    SELECT DISTINCT
        aa.Account_ID
        , 21 AS ProgramID
        , 22 AS TierID
    FROM #ApprovedAccounts AS aa
    WHERE (
        aa.TierCode NOT LIKE 'T1E%'
        AND aa.TierCode NOT LIKE 'T1X%'
    )
    AND aa.Account_ID NOT IN (SELECT AccountID FROM Account.tblAccountProgram WHERE ProgramID = 21 AND TierID = 22)


    INSERT INTO Account.tblAccountProgramHistory
    (
        Account_ID,
        CreateDate,
        Action,
        UserID,
        TierID
    )
    SELECT
        h.Account_ID,
        h.CreateDate,
        h.AddAction,
        h.UserID,
        h.AddTierID
    FROM #HistoryInsert AS h
    WHERE h.AddAction IS NOT NULL
    UNION
    SELECT
        h.Account_ID,
        h.CreateDate,
        h.RemoveAction,
        h.UserID,
        h.RemovedTierID
    FROM #HistoryInsert AS h
    WHERE h.RemoveAction IS NOT NULL


END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
