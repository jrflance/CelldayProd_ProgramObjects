--liquibase formatted sql

--changeset jrose:10C2A60D-5284-411A-9EB7-BF04E65BB8DC stripComments:false runOnChange:true endDelimiter:/

-- noqa: disable=all
-- =============================================
--             : 
--      Author : Jacob Lowe
--             : 
--     Created : 2017-12-04
--             : 
--       Usage : EXEC [Report].[P_Report_Pull_User_Information] @SessionAccountID = 2, @AccountStatus = -1, @TracStatus = 0, @TracTier = 0, @AccountList = ''
--             : 
-- Description : Ability to pull accounts AND users for Marketing
--             : 
--  JL20180426 : Fix VZW JOIN issue
--  LZ20181009 : INC125181
--  JR20240123 : Formatting. Corrected account status usage (at report Management level too).
--             : 
-- =============================================
-- noqa: enable=all
CREATE OR ALTER PROCEDURE [Report].[P_Report_Pull_User_Information]
    (
        @SessionAccountID INT,
        @AccountStatus INT,
        @TracStatus INT,
        @TracTier INT,
        @UltraDealerCode INT = 0,
        @VzwStatus INT = 255,
        @AccountList VARCHAR(MAX)
    )
AS
BEGIN TRY

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF (ISNULL(@SessionAccountID, 0) <> 2)
        BEGIN
            SELECT
                'This report is highly restricted! Please see your T-Cetra ' +
                'representative if you need access.' AS [Error Message];
            RETURN;
        END;

    DECLARE @LimitAccountID BIT = 0
-- noqa: disable=all
    DECLARE @Acct IDs
    -- noqa: enable=all

    BEGIN TRY
        INSERT INTO @Acct (ID)
        SELECT ID
        FROM dbo.fnSplitterLarge(LTRIM(@AccountList))
        IF @@ROWCOUNT > 0
            BEGIN
                SET @LimitAccountID = 1
            END
    END TRY
    BEGIN CATCH
        SELECT 'Invalid characters in account list.' AS [Error Message]
        RETURN;
    END CATCH

    IF
        @LimitAccountID = 1 AND EXISTS (
            SELECT 1 FROM Account AS ac
            JOIN @Acct AS a ON ac.Account_ID = a.ID WHERE ac.AccountType_ID NOT IN (2, 11)
        )
        BEGIN
            SELECT
                'Only merchant accounts can be submitted. Please check the account type ' +
                'of accounts you provided. ' AS [Error Message];
            RETURN;
        END

    IF OBJECT_ID('tempdb..#ListOfAccountStatuses') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfAccountStatuses;
        END;

    CREATE TABLE #ListOfAccountStatuses (AccountStatus INT);

    IF @AccountStatus = -1 -- All  -- JR20240123
        BEGIN
            INSERT INTO #ListOfAccountStatuses (AccountStatus)
            SELECT AccountStatus_ID
            FROM dbo.AccountStatus_ID;
        END
    ELSE
        BEGIN
            INSERT INTO #ListOfAccountStatuses (AccountStatus)
            VALUES (@AccountStatus)
        END;

    SELECT DISTINCT
        ac.Account_ID
        , cu.Email
        , asi.AccountStatus_Desc AS [AccountStatus]
        , ur.User_ID

        , CASE
            WHEN ur.Group_ID = 9
                THEN 'Manager'
            ELSE ''
        END AS [IsManager]

        , CASE
            WHEN ac.User_ID = ur.User_ID
                THEN 'Primary'
            ELSE ''
        END AS [IsPrimary]

        , ISNULL(tds.Status, '') AS [TracfoneStatus]
        , ISNULL(tt.TracTierName, '') AS [TracfoneTier]
        , ISNULL(adc.DealerCode, '') AS [UltraDealerCode]
        , ISNULL(vass.Description, '') AS [VzwStatus]

    FROM dbo.Account AS ac
    JOIN dbo.AccountStatus_ID AS asi ON asi.AccountStatus_ID = ac.AccountStatus_ID
    JOIN dbo.Users AS ur
        ON
            ur.Account_ID = ac.Account_ID
            AND ur.Status_ID = 1 AND ur.IsActive = 1

    JOIN dbo.Customers AS cu ON cu.Customer_ID = ac.Customer_ID
    JOIN #ListOfAccountStatuses AS las ON las.AccountStatus = ac.AccountStatus_ID

    LEFT JOIN Tracfone.tblTracTSPAccountRegistration AS tar ON tar.Account_ID = CAST(ac.Account_ID AS VARCHAR(16))
    LEFT JOIN Tracfone.tblTracfoneDealerStatus AS tds ON tds.TracfoneDealerStatusID = tar.TracfoneStatus
    LEFT JOIN Tracfone.tblTracTier AS tt ON tar.TracfoneTierId = tt.TracTierId

    LEFT JOIN CarrierSetup.tblAccountDealerCode AS adc
        ON
            adc.AccountID = ac.Account_ID
            AND adc.DealerCode <> 'UMTEMP'

    LEFT JOIN CarrierSetup.tblVzwAccountStore AS vas
        ON
            vas.AccountId = ac.Account_ID
            AND vas.StatusID <> 255

    LEFT JOIN CarrierSetup.tblVzwAccountStoreStatus AS vass ON vass.StatusID = vas.StatusID

    WHERE
        ac.AccountType_ID IN (2, 11)
        AND (ac.Account_ID IN (SELECT ID FROM @Acct) OR 0 = @LimitAccountID)   --- INC125181

        AND (
            @TracStatus = tar.TracfoneStatus
            OR ISNULL(@TracStatus, 0) = 0
        )

        AND (
            @TracTier = tar.TracfoneTierId
            OR ISNULL(@TracTier, 0) = 0
        )

        AND (
            CASE
                WHEN ISNULL(adc.DealerCode, '') = ''
                    THEN 2
                ELSE 1
            END = @UltraDealerCode
            OR ISNULL(@UltraDealerCode, 0) = 0
        )

        AND (
            @VzwStatus = vas.StatusID
            OR ISNULL(@VzwStatus, 255) = 255
        )

    ORDER BY ac.Account_ID

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber
        , ERROR_MESSAGE() AS ErrorMessage;
END CATCH;

-- noqa: disable=all
/
