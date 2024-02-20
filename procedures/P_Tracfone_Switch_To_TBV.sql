--liquibase formatted sql

--changeset NicolasGriesdorn:84ff8449 stripComments:false runOnChange:true splitStatements:false

CREATE OR ALTER PROCEDURE [Report].[P_Report_Tracfone_Switch_To_TBV]
    (@AccountID VARCHAR(MAX), @SessionID INT, @UserID INT)
AS
BEGIN
    ----Testing
    --DECLARE @AccountID VARCHAR(8) = 135944,
    --		@SessionID INT = 2,
    --		@UserID int = 227824
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
    DECLARE @Trancount SMALLINT;
    SET @Trancount = @@TRANCOUNT;

    BEGIN TRY

        IF (ISNULL(@SessionID, '') <> 2)
            BEGIN
                SELECT 'This report is restricted by account ID. Please see your' AS [Error]
                UNION
                SELECT 'T-Cetra representative if you need access!' AS [Error];
                RETURN;
            END;
        IF (ISNULL(@AccountID, '') = '')
            BEGIN
                SELECT 'This report requires an Account ID to be entered' AS [Error];
                RETURN;
            END;
        -- BEGIN Read Part 1

        IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
            BEGIN
                DROP TABLE #ListOfAccounts;
            END;
        SELECT ID AS [AccountId]
        INTO #ListOfAccounts
        FROM dbo.fnSplitter(@AccountID);
        /*This block borrowed from [Tracfone].[P_ProcessProgramTierAlignment] */
        --Part 2
        IF OBJECT_ID('tempdb..#HistoryInsert') IS NOT NULL
            BEGIN
                DROP TABLE #HistoryInsert;
            END;

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
        (37, 41);

        IF OBJECT_ID('tempdb..#TBVaccounts') IS NOT NULL
            BEGIN
                DROP TABLE #TBVaccounts;
            END;

        SELECT aa.AccountID
        INTO #TBVaccounts
        FROM #ListofAccounts AS aa

        IF OBJECT_ID('tempdb..#TBVaccountTiers') IS NOT NULL
            BEGIN
                DROP TABLE #TBVaccountTiers;
            END;

        SELECT
            t.AccountID,
            ProgramID, -- noqa: RF02
            TierID -- noqa: RF02
        INTO #TBVaccountTiers
        FROM #TBVaccounts AS t, #TBVtiers

        DELETE tbv
        FROM #TBVaccountTiers AS tbv
        JOIN account.tblAccountProgram AS p
            ON
                tbv.AccountID = p.AccountID
                AND tbv.ProgramID = p.ProgramID
                AND tbv.TierID = p.TierID

        --Part 3
        IF OBJECT_ID('tempdb..#TBVCreditTerms') IS NOT NULL
            BEGIN
                DROP TABLE #TBVCreditTerms;
            END;

        CREATE TABLE #TBVCreditTerms
        (OrderTypeID INT, CreditTermID INT, ACHGroupId NVARCHAR(50))


        INSERT INTO #TBVCreditTerms
        VALUES
        (48, 55, N'')
        , (49, 55, N'')
        , (57, 55, N'')
        , (58, 55, N'')

        IF OBJECT_ID('tempdb..#TBVAccountsCredit') IS NOT NULL
            BEGIN
                DROP TABLE #TBVAccountsCredit;
            END;

        SELECT ta.AccountID
        INTO #TBVAccountsCredit
        FROM #TBVaccounts AS ta

        IF OBJECT_ID('tempdb..#TBVAccountsCreditTerms') IS NOT NULL
            BEGIN
                DROP TABLE #TBVAccountsCreditTerms;
            END;

        SELECT
            t.AccountID,
            OrderTypeID, -- noqa: RF02
            CreditTermID, -- noqa: RF02
            ACHGroupId -- noqa: RF02
        INTO #TBVAccountsCreditTerms
        FROM #TBVAccountsCredit AS t, #TBVCreditTerms

        --BEGIN Write Part
        IF @Trancount = 0 BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (AccountID INT);
        --Part 1

        MERGE account.tblTags AS tt
        USING #ListOfAccounts AS la
            ON tt.SubjectId = la.AccountId AND tt.Tag = 'TER'
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (SubjectId, SubjectTypeId, Tag)
            VALUES (la.AccountId, 1, 'TER')
        OUTPUT Inserted.SubjectId INTO @Inserted;


        MERGE account.tblTags AS tt
        USING #ListOfAccounts AS la
            ON tt.SubjectId = la.AccountId AND tt.Tag = 'ProgramExclusive'
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (SubjectId, SubjectTypeId, Tag)
            VALUES (la.AccountId, 1, 'ProgramExclusive')
        OUTPUT Inserted.SubjectId INTO @Inserted;

        MERGE account.tblTags AS tt
        USING #ListOfAccounts AS la
            ON tt.SubjectId = la.AccountId AND tt.Tag = 'TBV'
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (SubjectId, SubjectTypeId, Tag)
            VALUES (la.AccountId, 1, 'TBV')
        OUTPUT Inserted.SubjectId INTO @Inserted;

        MERGE Tracfone.tblTracTSPAccountRegistration AS tspar
        USING #ListOfAccounts AS la
            ON CAST(la.AccountId AS VARCHAR(MAX)) = tspar.Account_ID
        WHEN MATCHED THEN UPDATE SET tspar.TracfoneTierId = 3;

        /*Updating the TierId if the program ID matches and inserting a new TierID if not.*/
        --Part 2

        MERGE Account.tblAccountProgram AS ap
        USING #TBVaccountTiers AS tbv
            ON
                tbv.AccountID = ap.AccountID
                AND tbv.ProgramID = ap.ProgramID
        WHEN MATCHED
            THEN
            UPDATE SET ap.TierID = tbv.TierID
        WHEN NOT MATCHED BY TARGET
            THEN
            INSERT (AccountID, ProgramID, TierID)
            VALUES (tbv.AccountID, tbv.ProgramID, tbv.TierID)
        OUTPUT
            Inserted.AccountID,
            GETDATE(),
            'Add',
            'SwitchTBVProc',
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
        -- Part 3

        MERGE MarketPlace.tblAccountBrandedMPTier AS abm
        USING #ListOfAccounts AS la
            ON la.AccountID = abm.AccountID AND BrandedMPID = 10
        WHEN MATCHED THEN DELETE;

        MERGE MarketPlace.tblAccountBrandedMPTier AS abm
        USING #ListOfAccounts AS la
            ON la.AccountID = abm.AccountID AND BrandedMPID = 10
        WHEN NOT MATCHED
            THEN INSERT (AccountID, BrandedMPID, BrandedMPTierID, DateUpdated, UpdateUserID, Status)
            VALUES (la.AccountID, 10, 61, GETDATE(), 'SwitchAccToTBVProc', 1);

        MERGE Account.tblAccountCreditTerms AS act
        USING #TBVAccountsCreditTerms AS tbvact
            ON tbvact.AccountId = act.AccountId AND tbvact.OrderTypeID = act.OrderTypeId
        WHEN MATCHED
            THEN
            UPDATE SET act.CreditTermId = 55
        WHEN NOT MATCHED
            THEN
            INSERT (AccountId, OrderTypeId, CreditTermId, ACHGroupId)
            VALUES (tbvact.AccountId, tbvact.OrderTypeID, tbvact.CreditTermID, N'');

        -- Should not have b2b by deafult, will be added later on by b2b intructions  FS
        MERGE Account.tblB2BAccounts AS b2b
        USING #ListOfAccounts AS la
            ON la.AccountId = b2b.AccountId
        WHEN MATCHED THEN UPDATE SET b2b.Status = 0
        WHEN NOT MATCHED
            THEN INSERT (AccountId, Status)
            VALUES (la.AccountId, 0);
        IF @Trancount = 0 COMMIT TRANSACTION;

        -- No Edits Beyond here
        SELECT
            a.Account_ID
            , a.Account_Name
            , t1.Tag
            , tcba.TracfoneCode
            , p.Name AS [Program Name]
            , pt.Name AS [Program Tier Name]
            , bb.Status
            , a.ApprovedTotalCreditLimit_Amt
            , a.AvailableTotalCreditLimit_Amt
            , a.ApprovedDailyCreditLimit_Amt
            , a.AvailableDailyCreditLimit_Amt
            , bt.TierName AS [Branded Tier Name]
        FROM dbo.Account AS a
        JOIN Account.tblTags AS t1
            ON
                a.Account_ID = t1.SubjectId
                AND a.Account_ID IN (SELECT AccountID FROM #ListOfAccounts)
                AND t1.Tag = 'TBV'
        JOIN Tracfone.tblTracTSPAccountRegistration AS tr
            ON tr.Account_ID = CAST(a.Account_ID AS VARCHAR(8))
        JOIN tracfone.TFCodeBrandedAlignment AS tcba
            ON tcba.BrandedMPTierName = t1.Tag
        JOIN Account.tblAccountProgram AS pa
            ON pa.AccountID = a.Account_ID
        JOIN #TBVtiers AS tbv
            ON
                pa.ProgramID = tbv.ProgramID
                AND pa.TierID = tbv.TierID
        JOIN Account.tblProgram AS p
            ON p.ProgramID = tbv.ProgramID
        JOIN Account.tblProgramTier AS pt
            ON
                pt.ProgramID = tbv.ProgramID
                AND pt.TierID = tbv.TierID
        LEFT JOIN Account.tblB2BAccounts AS bb
            ON bb.AccountId = a.Account_ID
        JOIN MarketPlace.tblAccountBrandedMPTier AS bta
            ON
                bta.AccountID = bb.AccountId
                AND bta.BrandedMPID = 10 --TBV
                AND bta.Status = 1
        LEFT JOIN MarketPlace.tblBrandedMPTiers AS bt
            ON
                bt.BrandedMPID = bta.BrandedMPID AND
                bt.BrandedMPTierID = bta.BrandedMPTierID
        WHERE a.Account_ID IN (SELECT AccountID FROM #ListOfAccounts)
        ORDER BY a.Account_ID

        DROP TABLE IF EXISTS #ListOfAccounts
        DROP TABLE IF EXISTS #TBVaccounts
        DROP TABLE IF EXISTS #TBVtiers
        DROP TABLE IF EXISTS #TBVaccountTiers
        DROP TABLE IF EXISTS #HistoryInsert
        DROP TABLE IF EXISTS #TBVCreditTerms
        DROP TABLE IF EXISTS #TBVAccountsCredit
        DROP TABLE IF EXISTS #TBVAccountsCreditTerms
    END TRY
    BEGIN CATCH
        IF @Trancount = 0 ROLLBACK TRANSACTION;
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;
END;
