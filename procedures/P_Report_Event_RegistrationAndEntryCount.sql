--liquibase formatted sql

--changeset jrose:34D98088-CF56-4FBB-90C9-77C96C5D50B3 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
-- =============================================
--             : 
-- Author      : Morgan Kemp
--             : 
-- Created     : 2021-10-07
--             : 
-- Description : Recreation of the [Report].[P_Report_Event_Registration] SP to show single rows of accounts with their current most counts
--             : 
-- Usage       : EXEC [Report].[P_Report_Event_RegistrationAndEntryCount] 2, 1, '2019-02-18', '2019-03-09'
--             :
-- NG2021117   : Added ability to enter Min or Max number of Entries based on User input
-- NG2021130   : Cleaned up Selects and added Joins to final Select for cleaner indexing of query for future use.
-- LUX20220225 : Changed report to handle VZW and TF in Tax Time Treasure Event
-- LUX20220228 : Added MA name;  Added registered dealers without o entries 
-- LUX20220301 : Added parameter for Carrier
-- MR20220311  : Added contraint of  m.EventId = @EventID when gathering TracFone and Verizon accounts.
--             : Switched from a JOIN to a LEFT JOIN for Tracfone.tblTracfoneMAIDMapping, and added an ISNULL for the MA Account here.
--             : Added section #DoubleCarrier to remove the carrier that isn't used if an account is registered for both TF and VZW.
--             : Re-arranged the final select statment to start with [Marketing].[tblEventRegistration] to show all accounts registered
--             :    rather than starting with #combined_acct_status which excluded many accounts.
--             : Excluded  "Pending Data Resubmitted" status from Tracfone Accounts
-- MR20220707  : Changed parameters of EventName and Carrier to be varchar for easier report usability in SSRS.
-- MR20230217  : Adapted for Game of Phones event (changed entry types)
-- MR20230227  : Lumped each entry type together for each account to speed up the report. Took out accounts that have zero entries.
-- MR20230316  : Added a TBV temp table and a column to show if an account was in the program-tier TBV.
-- MR20230323  : Added new section to show the 3X plans separate from the other Activations.
-- MR20230404  : Changed the Name column to pull from the temp table rather than orders table in the #ThreeXplans section.
--             : commented out some un-unecessary final tables in the last select for optimization.
-- JR20240212  : Formatting.
--             : 
-- =============================================
-- noqa: enable=all
ALTER PROCEDURE [Report].[P_Report_Event_RegistrationAndEntryCount]
    (
        @SessionID INT
        , @EventName VARCHAR(50) -- 'Game of Phones - 2023 Tax Time Contest'
        , @Carrier VARCHAR(50) -- 'All'
        , @MinEntries INT
        , @MaxEntries INT
        , @StartDate DATETIME = NULL
        , @EndDate DATETIME = NULL
    )
AS
BEGIN
    BEGIN TRY

        SET NOCOUNT ON;

        DECLARE @CarrierName NVARCHAR(100);

        SELECT
            @CarrierName = CASE @Carrier
                WHEN 'All' THEN '%'
                WHEN 'TracFone' THEN '%TracFone%'
                WHEN 'Verizon' THEN '%Verizon%'
                ELSE '%'
            END
        DECLARE @EventID INT;

        SET @EventID = (SELECT EventId FROM Marketing.tblEvents WHERE Name = @EventName)

        IF (ISNULL(@SessionID, 0) <> 2)
            BEGIN
                SELECT
                -- noqa: disable=all
                    'This report is highly restricted! Please see your T-Cetra representative if you need access.' AS [Error Message];
                -- noqa: enable=all
                RETURN;
            END;

        DECLARE @BeginPeriod DATETIME = @StartDate;
        DECLARE @EndPeriod DATETIME = @EndDate;

        IF @EndPeriod IS NULL OR @EndPeriod = ''
            BEGIN
                SET @EndPeriod = (
                    SELECT ISNULL(EndDate, GETDATE())
                    FROM [Marketing].[tblEvents]
                    WHERE [EventId] = @EventID
                )
            END

        IF @BeginPeriod IS NULL OR @BeginPeriod = ''
            BEGIN
                SET @BeginPeriod = (
                    SELECT ISNULL(StartDate, GETDATE())
                    FROM [Marketing].[tblEvents]
                    WHERE [EventId] = @EventID
                )
            END

        IF @BeginPeriod > @EndPeriod
            BEGIN
                SELECT '"Start Date:" can not be later than the "End Date:",' AS [Error]
                UNION
                SELECT '      please re-enter your dates!' AS [Error];
                RETURN;
            END;

        IF @MinEntries = ''
            SET @MinEntries = NULL;

        IF @MaxEntries = ''
            SET @MaxEntries = NULL;

        DROP TABLE IF EXISTS #registered_accounts;

        SELECT AccountId
        INTO #registered_accounts
        FROM Marketing.tblEventRegistration
        WHERE EventId = @EventID;

        DROP TABLE IF EXISTS #TBVaccounts

        SELECT ra.AccountId
        INTO #TBVaccounts            --MR20230316
        FROM #registered_accounts AS ra
        JOIN Account.tblAccountProgram AS ac WITH (NOLOCK)
            ON
                ac.AccountID = ra.AccountId
                AND ac.TierID = 40          --TBV
                AND ac.ProgramID = 36
        DROP TABLE IF EXISTS #tf_account_status;

        SELECT
            tr.Account_ID AS [AccountID],
            st.Status,
            ma.TracfoneMAID,
            CAST('TracFone' AS VARCHAR(100)) AS [Carrier], --MR20220311
            ISNULL(ma.TracfoneMAID, dbo.fn_GetTopParentAccountID_NotTcetra_2(ac.Account_ID)) AS [MA]
        INTO #tf_account_status
        FROM Tracfone.tblTracTSPAccountRegistration AS tr WITH (NOLOCK)
        JOIN dbo.Account AS ac WITH (NOLOCK) ON CAST(ac.Account_ID AS VARCHAR(30)) = tr.Account_ID
        JOIN Tracfone.tblTracfoneDealerStatus AS st WITH (NOLOCK) ON st.TracfoneDealerStatusID = tr.TracfoneStatus
        --MR20220311
        LEFT JOIN
            Tracfone.tblTracfoneMAIDMapping AS ma WITH (NOLOCK)
            ON dbo.fn_GetTopParentAccountID_NotTcetra_2(ac.Account_ID) = ma.TopParentID

        WHERE tr.Account_ID IN (
            SELECT CAST(AccountId AS BIGINT)
            FROM Marketing.tblEventRegistration WITH (NOLOCK)
            WHERE EventId = @EventID
        )          --MR20220311
        AND st.TracfoneDealerStatusID NOT IN (2, 3, 5, 7, 8, 10);  --MR20220311 excluding "Pending Data Resubmitted"

        DROP TABLE IF EXISTS #vz_account_status;

        SELECT
            vzwa.AccountId,
            st.Description AS [Status],
            'Verizon' AS Carrier,
            dbo.fn_GetTopParent_NotTcetra_h(ac.Hierarchy) AS [MA]
        INTO #vz_account_status
        FROM dbo.Account AS ac WITH (NOLOCK)
        JOIN CarrierSetup.tblVzwAccountStore AS vzwa WITH (NOLOCK) ON ac.Account_ID = vzwa.AccountId
        JOIN CarrierSetup.tblVzwAccountStoreStatus AS st WITH (NOLOCK) ON st.StatusID = vzwa.StatusID

        WHERE
            vzwa.AccountId IN (
                SELECT CAST(AccountId AS BIGINT)
                FROM Marketing.tblEventRegistration
                WHERE EventId = @EventID
            )         --MR20220311
            AND st.StatusID NOT IN (2, 5, 8, 9, 10, 11, 255)

        DROP TABLE IF EXISTS #combined_acct_status;

        SELECT AccountID, Status, Carrier, MA
        INTO #combined_acct_status
        FROM #tf_account_status
        UNION
        SELECT AccountId, Status, Carrier, MA
        FROM #vz_account_status

        DROP TABLE IF EXISTS #RnumCombined_Acct_status;

        SELECT AccountID, Status, Carrier, MA, ROW_NUMBER() OVER (PARTITION BY AccountID ORDER BY Carrier) AS [Rnum]
        INTO #RnumCombined_Acct_status
        FROM #combined_acct_status

        DROP TABLE IF EXISTS #DoubleCarrier;   --MR20220311 Section added

        SELECT DISTINCT
            r1.AccountID,
            r1.Status,
            r1.Carrier,
            r1.MA,
            IIF(ee.EntryType = 'TracfoneOrderNumber', 'Tracfone', 'Verizon') AS EntryType
        INTO #DoubleCarrier
        FROM #RnumCombined_Acct_status AS r1
        JOIN Marketing.tblEventEntries AS ee WITH (NOLOCK)
            ON
                ee.AccountId = r1.AccountID
                AND ee.EventId = 5
                AND ee.EntryType IN ('TracfoneOrderNumber', 'VerizonOrderNumber')
        WHERE
            EXISTS (
                SELECT 1 FROM #RnumCombined_Acct_status AS r2
                WHERE
                    r2.AccountID = r1.AccountID
                    AND r2.Rnum = 2
            )

        DELETE ca                        --MR20220311
        FROM #combined_acct_status AS ca
        JOIN #DoubleCarrier AS dc
            ON
                ca.AccountID = dc.AccountID
                AND dc.Carrier <> dc.EntryType
        WHERE ca.Carrier = dc.Carrier

        ---------------------------------new MR20230323 to get 3X plans---------------------

        DROP TABLE IF EXISTS #ActivationProducts;

        SELECT
            pd.Product_ID, pd.Name,
            pd.ProductAdditionalInfo_ID,

            pcm.CarrierId,
            TRY_PARSE(LEFT(
                SUBSTRING(pd.name, CHARINDEX('$', pd.name), 8000),
                PATINDEX('%[^0-9.-]%', SUBSTRING(pd.name, CHARINDEX('$', pd.name) + 1, 8000) + 'X')
            ) AS MONEY) AS PlanPrice,
            CASE
                WHEN
                    pd.name LIKE '%x%' AND TRY_PARSE(LEFT(
                        SUBSTRING(pd.name, CHARINDEX('$', pd.name), 8000),
                        PATINDEX('%[^0-9.-]%', SUBSTRING(pd.name, CHARINDEX('$', pd.name) + 1, 8000) + 'X')
                    ) AS MONEY)
                    >= 49.99
                    THEN 50
                WHEN
                    pd.name LIKE '%x%' AND TRY_PARSE(LEFT(
                        SUBSTRING(pd.name, CHARINDEX('$', pd.name), 8000),
                        PATINDEX('%[^0-9.-]%', SUBSTRING(pd.name, CHARINDEX('$', pd.name) + 1, 8000) + 'X')
                    ) AS MONEY)
                    < 49.99
                    THEN 20
                WHEN
                    TRY_PARSE(LEFT(
                        SUBSTRING(pd.name, CHARINDEX('$', pd.name), 8000),
                        PATINDEX('%[^0-9.-]%', SUBSTRING(pd.name, CHARINDEX('$', pd.name) + 1, 8000) + 'X')
                    ) AS MONEY)
                    >= 49.99
                    AND pd.name NOT LIKE '%x%'
                    THEN 20
                ELSE 0
            END AS Entries
        INTO #ActivationProducts
        FROM dbo.products AS pd
        JOIN Products.tblProductCarrierMapping AS pcm WITH (NOLOCK)
            ON
                pcm.ProductId = pd.Product_ID
                AND pcm.CarrierId IN (4, 7, 292)
        JOIN Products.tblProductType AS pt WITH (NOLOCK) ON pd.Product_Type = pt.ProductTypeID
        WHERE
            pd.Product_Type = 3 --activation
            AND pd.Display = 1
            AND pd.NotSold = 0

        DELETE p
        FROM #ActivationProducts AS p
        WHERE p.Entries = 0

        DELETE p
        FROM #ActivationProducts AS p
        JOIN
            dbo.ProductAdditionalInfo_ID AS pa WITH (NOLOCK)
            ON p.ProductAdditionalInfo_ID = pa.ProductAdditionalInfo_ID
        WHERE
            p.CarrierId = 7
            AND pa.ProductAdditionalInfo_ID <> 238

        DELETE p
        FROM #ActivationProducts AS p
        WHERE p.Name NOT LIKE '%x%'

        --SELECT * FROM #ActivationProducts

        DROP TABLE IF EXISTS #ThreeXplans;

        SELECT ee.AccountId, ee.EntryType, ee.EntryID, ap.Name            --MR20230404
        INTO #ThreeXplans
        FROM [Marketing].[tblEventEntries] AS ee WITH (NOLOCK)
        JOIN [dbo].[Orders] AS os WITH (NOLOCK) ON os.id = ee.EntryID
        JOIN #ActivationProducts AS ap ON ap.Product_ID = os.Product_ID
        WHERE
            ee.EventId = 7
            AND ee.EntryType = 'Activation'

        DROP TABLE IF EXISTS #tempEventAccounts;

        CREATE TABLE #tempEventAccounts (
            Account_ID INT,
            Category_Name VARCHAR(100),
            NumberOfEntries DECIMAL(7, 2)
        );

        INSERT INTO #tempEventAccounts (Account_ID, Category_Name, NumberOfEntries)
        SELECT
            ea.AccountId,
            CASE ea.EntryType
                WHEN 'OrderID'
                    THEN 'Flash Sale'
                ELSE ea.EntryType
            END
                AS [Category_Name],
            SUM(ea.NumberOfEntries) AS [NumberOfEntries]
        FROM (
            SELECT
                ee.AccountId,
                CASE
                    WHEN x3.EntryType IS NOT NULL
                        THEN '3xPlans'
                    ELSE ee.EntryType
                END
                    AS EntryType,
                SUM(ISNULL(ee.NumberOfEntries * ee.WeightOfEntries, 0)) AS [NumberOfEntries]

            FROM [Marketing].[tblEventEntries] AS ee WITH (NOLOCK)
            LEFT JOIN #ThreeXplans AS x3 ON x3.EntryID = ee.EntryID
            WHERE ee.EventId = 7
            GROUP BY
                ee.AccountId,
                ee.EntryType,
                x3.EntryType
        ) AS ea
        GROUP BY
            ea.AccountId,
            ea.EntryType;


        --INSERT INTO #tempEventAccounts
        --SELECT AccountId,
        --       NULL AS Order_No,
        --       NULL AS EntryType,
        --       0 AS NumberOfEntries
        --FROM #registered_accounts r
        --WHERE NOT EXISTS
        --(
        --    SELECT 1 FROM #tempEventAccounts ea WHERE ea.Account_ID = r.AccountId
        --);

        -----------------------------------------------
        --SELECT * FROM #tempEventAccounts  WHERE Account_Id IN (28592,28731,29450) ORDER BY Account_ID
        -----------------------------------------------

        --IF OBJECT_ID('tempdb..#OtherResults') IS NOT NULL
        --   BEGIN
        --       DROP TABLE #OtherResults;
        --   END;

        SELECT DISTINCT
            ev.Name AS [Name],
            er.AccountId AS [Account ID],
            ac.Account_Name AS [Account Name],
            cu.FirstName AS [First Name],

            cu.LastName AS [Last Name],
            cu.City,
            cu.State,

            cu.Zip,
            cu.Phone,
            cu.Email,
            NULL AS [Order_No],
            [cas].[Carrier],
            ac3.Account_ID AS [MA],
            ac3.Account_Name AS [MA Name],
            t.Category_Name,

            t.NumberOfEntries,

            CAST(CONVERT(DATETIME, er.RegistrationDate, 120) AS VARCHAR(19))
                AS [Registration Date],
            ISNULL(cas.Status, asi.AccountStatus_Desc) AS [Account Status],
            CASE
                WHEN cu.Address2 IS NOT NULL AND cu.Address2 <> ''
                    THEN cu.Address1 + ', ' + cu.Address2
                ELSE
                    cu.Address1
            END
                AS [Address],
            IIF(tbv.AccountId IS NOT NULL, 'yes', 'no') AS [IsTBVaccount]
            --INTO #OtherResults
        FROM [Marketing].[tblEventRegistration] AS er WITH (NOLOCK)            --MR20220311 re-arranged
        LEFT JOIN #tempEventAccounts AS t
            ON t.Account_ID = er.AccountId
        --AND t.NumberOfEntries  
        -- BETWEEN ISNULL(@MinEntries, t.NumberOfEntries) AND ISNULL(@MaxEntries, t.NumberOfEntries)

        LEFT JOIN #combined_acct_status AS cas
            ON
                t.Account_ID = cas.AccountID
                AND cas.Carrier LIKE @CarrierName

        JOIN [Marketing].[tblEvents] AS ev WITH (NOLOCK)
            ON
                er.EventId = ev.EventId
                AND ev.EventId = @EventID
        -- JOIN [Marketing].[tblEventType] et WITH (NOLOCK) ON ev.EventTypeId = et.EventTypeId

        JOIN [dbo].[Account] AS ac WITH (NOLOCK)
            ON
                er.AccountId = ac.Account_ID
                AND ISNULL(ac.IstestAccount, 0) = 0 --there are 5 test accounts in the EventRegistration Table

        JOIN dbo.AccountStatus_ID AS asi WITH (NOLOCK) ON asi.AccountStatus_ID = ac.AccountStatus_ID

        JOIN [dbo].[Customers] AS cu WITH (NOLOCK) ON ac.Contact_ID = cu.Customer_ID

        JOIN [Marketing].[tblEventEntries] AS ee WITH (NOLOCK)
            ON
                er.AccountId = ee.AccountId
                AND ee.EventId = @EventID

        --LEFT JOIN dbo.Account ac2 WITH (NOLOCK) ON ac2.Account_ID = cas.[MA]

        LEFT JOIN dbo.Account AS ac3 ON ac3.Account_ID = CAST(dbo.fn_GetTopParent_NotTcetra_h(ac.Hierarchy) AS INT)

        LEFT JOIN #TBVaccounts AS tbv ON tbv.AccountId = er.AccountId

        ORDER BY er.AccountId;

        DROP TABLE IF EXISTS #registered_accounts;
        DROP TABLE IF EXISTS #tf_account_status;
        DROP TABLE IF EXISTS #vz_account_status;
        DROP TABLE IF EXISTS #combined_acct_status;
        DROP TABLE IF EXISTS #DoubleCarrier;
        DROP TABLE IF EXISTS #TBVaccounts;
        DROP TABLE IF EXISTS #ActivationProducts;
        DROP TABLE IF EXISTS #ThreeXplans;

    END TRY
    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage;
    END CATCH
END
-- noqa: disable=all
/
