--liquibase formatted sql

--changeset KarinaMasihHudson:71a4e5818ddf42229eb14e507eb8a9ec stripComments:false runOnChange:true splitStatements:false
/* =============================================
      Author : Karina Masih-Hudson
     Created : 2024-05-24
 Description : CRM report that marks the account to be submitted to Genmobile
             : Modeled after P_Report_MA_Account_Send_Cricket
			 : Action: Submit New|0|
					   Update|1|
 =============================================*/
CREATE OR ALTER PROCEDURE [Report].[P_Report_MA_Account_Send_Genmobile]
    (
        @Account VARCHAR(MAX)
        , @TotalMonthlyAct INT
        , @GMMonthlyAct INT
        , @PrefLanguage NVARCHAR(25)
        , @Notes VARCHAR(MAX)
        , @Action BIT --Show|0|Update|1|
        , @SessionAccountID INT
    )
AS

BEGIN TRY
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    --DECLARE
    --	@Account VARCHAR(MAX) = '13379'  --, 117783
    --	, @TotalMonthlyAct INT = 150
    --	, @GMMonthlyAct INT = 200
    --	, @PrefLanguage NVARCHAR(25) = 'Spanish'
    --	, @Notes VARCHAR(MAX) = 'testing'
    --	, @Action BIT = 1  --Submit New|0|Update|1|
    --	, @SessionAccountID INT = 2

    DECLARE @GMStoreID VARCHAR(10) = NULL

    IF (ISNULL(@Account, '') = '')
        BEGIN
            SELECT 'Must enter Account IDs' AS [Error Message];
            RETURN;
        END;

    IF (ISNULL(@SessionAccountID, 0) = 0)
        BEGIN
            SELECT 'Must have valid Session ID' AS [Error Message];
            RETURN;
        END;

    IF (ISNULL(@TotalMonthlyAct, 0) = 0 OR ISNULL(@GMMonthlyAct, 0) = 0 OR ISNULL(@PrefLanguage, '') = '')
        BEGIN
            SELECT 'Must enter Total Monthly Activation, Gen mobile monthly activation forecast and Preferred Language' AS [Error Message]
            RETURN;
        END;


    IF
        NOT EXISTS
        (
            SELECT TOP 1
                1
            FROM dbo.Account AS a
            JOIN dbo.DiscountClass_Products AS dcp
                ON dcp.DiscountClass_ID = a.DiscountClass_ID
            LEFT JOIN dbo.account_products_discount AS apd
                ON
                    apd.Account_ID = a.Account_ID
                    AND apd.Product_ID = dcp.Product_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = dcp.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm
                ON pcm.ProductId = p.Product_ID
            WHERE
                a.Account_ID = @SessionAccountID
                AND dcp.ApprovedToSell_Flg = 1
                AND ISNULL(apd.ApprovedToSell_Flg, dcp.ApprovedToSell_Flg) = 1
                AND p.Product_Type = 3
                AND p.NotSold = 0
                AND p.Display = 1
                AND pcm.CarrierId = 270  --gen mobile
        )
        BEGIN
            SELECT 'No Gen mobile Activation Products open to your account' AS [Error Message];
            RETURN;
        END;

    IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfAccounts;
        END;

    CREATE TABLE #ListOfAccounts
    (
        AccountID INT,
        info VARCHAR(MAX)
    );
    INSERT INTO #ListOfAccounts
    (
        AccountID,
        info
    )
    SELECT
        ID,
        '' AS info
    FROM dbo.fnSplitter(@Account);

    UPDATE la
    SET la.info = 'Account not under your account'
    FROM #ListOfAccounts AS la
    JOIN dbo.Account AS a
        ON la.AccountID = a.Account_ID
    WHERE
        a.HierarchyString NOT LIKE '%/' + CAST(@SessionAccountID AS VARCHAR(MAX)) + '/%'
        AND la.info = '';


    UPDATE la
    SET la.info = 'Account not a Merchant Account'
    FROM #ListOfAccounts AS la
    LEFT JOIN dbo.Account AS a
        ON la.AccountID = a.Account_ID
    WHERE
        ISNULL(a.AccountType_ID, 0) NOT IN (2, 11)
        AND la.info = '';


    UPDATE la
    SET la.info = 'Account Set Up is Incomplete'
    FROM #ListOfAccounts AS la
    JOIN dbo.Account AS a
        ON la.AccountID = a.Account_ID
    LEFT JOIN dbo.Customers AS c
        ON c.Customer_ID = a.Contact_ID
    WHERE (
        ISNULL(a.Account_Name, '') = ''
        OR ISNULL(c.Address1, '') = ''
        OR ISNULL(c.City, '') = ''
        OR ISNULL(c.State, '') = ''
        OR ISNULL(c.Zip, '') = ''
        OR ISNULL(c.Phone, '') = ''
        OR ISNULL(c.Email, '') = ''
        OR ISNULL(c.FirstName, '') = ''
        OR ISNULL(c.LastName, '') = ''
    )
    AND la.info = '';

    IF OBJECT_ID('tempdb..#Base') IS NOT NULL
        BEGIN
            DROP TABLE #Base;
        END;

    SELECT
        ac.Account_ID,
        REPLACE(
            REPLACE(
                CASE
                    WHEN LEN(ISNULL(ac.DoingBusinessAs_Name, '')) = 0
                        THEN
                            ac.Account_Name
                    ELSE
                        ac.DoingBusinessAs_Name
                END,
                ' ',
                ''
            ),
            '''',
            ''
        ) AS [DBA],
        COALESCE(piim.Token, ac.FederalTaxID) AS TaxID,
        cu.Address1,
        cu.Zip,
        (
            CASE
                WHEN LEN(ISNULL(cu.Phone, '')) = 0
                    THEN
                        cu.Phone2
                ELSE
                    cu.Phone
            END
        ) AS [Phone],
        cu.Email
    INTO #Base
    FROM CarrierSetup.tblGenmobileAccountStore AS ga
    JOIN dbo.Account AS ac
        ON ac.Account_ID = ga.AccountId
    JOIN dbo.Customers AS cu
        ON cu.Customer_ID = ac.Contact_ID
    LEFT JOIN Security.tblPiiMapping AS piim
        ON CAST(PIIM.[PiiMappingId] AS NVARCHAR(10)) = ac.FederalTaxID
    WHERE ga.StatusID <> 255;

    IF OBJECT_ID('tempdb..#ToCheck') IS NOT NULL
        BEGIN
            DROP TABLE #ToCheck;
        END;

    SELECT
        ac.Account_ID,
        REPLACE(
            REPLACE(
                CASE
                    WHEN LEN(ISNULL(ac.DoingBusinessAs_Name, '')) = 0
                        THEN
                            ac.Account_Name
                    ELSE
                        ac.DoingBusinessAs_Name
                END,
                ' ',
                ''
            ),
            '''',
            ''
        ) AS [DBA],
        COALESCE(piim.Token, ac.FederalTaxID) AS TaxID,
        cu.Address1,
        cu.Zip,
        (
            CASE
                WHEN LEN(ISNULL(cu.Phone, '')) = 0
                    THEN
                        cu.Phone2
                ELSE
                    cu.Phone
            END
        ) AS [Phone],
        cu.Email
    INTO #ToCheck
    FROM #ListOfAccounts AS la
    JOIN dbo.Account AS ac
        ON ac.Account_ID = la.AccountID
    JOIN dbo.Customers AS cu
        ON cu.Customer_ID = ac.Contact_ID
    LEFT JOIN Security.tblPiiMapping AS piim
        ON CAST(PIIM.[PiiMappingId] AS NVARCHAR(10)) = ac.FederalTaxID
    WHERE la.info = '';

    IF @Action = 0
        BEGIN

            UPDATE la
            SET la.info = 'Previously Submitted, Current Status: ' + tas.Description
            FROM #ListOfAccounts AS la
            JOIN CarrierSetup.tblGenmobileAccountStore AS a
                ON la.AccountID = a.AccountId
            JOIN CarrierSetup.tblAccountStoreStatus AS tas
                ON tas.StatusID = a.StatusID
            WHERE
                a.StatusID <> 255
                AND la.info = '';

            INSERT INTO CarrierSetup.tblGenmobileAccountStore
            (
                AccountId,
                GMStoreId,
                StatusID,
                OutletID,
                Comments,
                TotalMonthlyActivation,
                GMMonthlyActivationForecast,
                PrefLang,
                Update_Tms
            )
            SELECT
                la.AccountID,
                ISNULL(@GMStoreID, '') AS GMStoreID,
                255 AS StatusID,
                NULL AS OutletID,
                ISNULL(@Notes, '') AS Comments,
                @TotalMonthlyAct AS TotalMonthlyActivation,
                @GMMonthlyAct AS GMMonthlyActivationForecast,
                @PrefLanguage AS PrefLang,
                GETDATE() AS Update_Tms
            FROM #ListOfAccounts AS la
            WHERE
                NOT EXISTS
                (
                    SELECT 1
                    FROM CarrierSetup.tblGenmobileAccountStore AS gas
                    WHERE la.AccountID = gas.AccountId
                )
                AND la.info = '';
        END;

    IF
        @Action = 1
        AND (
            SELECT s.StatusID
            FROM CarrierSetup.tblGenmobileAccountStore AS s
            JOIN #ListOfAccounts AS l
                ON l.AccountID = s.AccountId
        )
        IN (2, 1, 255) --Pending, Need Review, Ignore
        AND (
            SELECT l.info
            FROM #ListOfAccounts AS l
        ) = ''

        BEGIN
            UPDATE gas
            SET
                gas.TotalMonthlyActivation = @TotalMonthlyAct,
                gas.GMMonthlyActivationForecast = @GMMonthlyAct,
                gas.PrefLang = @PrefLanguage
            --SELECT @TotalMonthlyAct, @GMMonthlyAct, @PrefLanguage
            FROM CarrierSetup.tblGenmobileAccountStore AS gas
            JOIN #ListOfAccounts AS la
                ON la.AccountID = gas.AccountId

            IF (ISNULL(@Notes, '') <> '')
                BEGIN
                    UPDATE gas
                    SET gas.Comments = @Notes
                    FROM CarrierSetup.tblGenmobileAccountStore AS gas
                    JOIN #ListOfAccounts AS la
                        ON la.AccountID = gas.AccountId;
                END;
        END

    IF
        @Action = 1
        AND (
            SELECT s.StatusID
            FROM CarrierSetup.tblGenmobileAccountStore AS s
            JOIN #ListOfAccounts AS l ON l.AccountID = s.AccountId
        )
        NOT IN (2, 1, 255) --Pending, Need Review, Ignore
        BEGIN
            UPDATE la
            SET la.info = 'Cannot update this account'
            FROM #ListOfAccounts AS la
            WHERE la.info = '';
        END


    --FRAUD
    UPDATE gas
    SET
        gas.StatusID = 9,
        gas.Update_Tms = GETDATE(),
        gas.Comments = ISNULL(@Notes, '') + '|Check Account:' + CAST(tc.Account_ID AS VARCHAR(MAX)) + '|'
    OUTPUT
        Inserted.AccountId,
        270 AS CarrierID,
        Deleted.StatusID,
        Inserted.StatusID
    INTO
        Logs.tblAccountStoreLogs
        (
            AccountID,
            CarrierID,
            OldStatusID,
            NewStatusID
        )
    FROM CarrierSetup.tblGenmobileAccountStore AS gas
    JOIN #ToCheck AS t
        ON gas.AccountId = t.Account_ID
    JOIN #Base AS tc
        ON
            t.Address1 = tc.Address1
            AND t.Zip = tc.Zip
    JOIN CarrierSetup.tblGenmobileAccountStore AS gas2
        ON
            gas2.AccountId = tc.Account_ID
            AND gas2.StatusID = 9
    WHERE (
        tc.Account_ID IS NOT NULL
        OR LEN(ISNULL(t.Address1, '')) = 0
        OR LEN(ISNULL(t.DBA, '')) = 0
        OR LEN(ISNULL(t.TaxID, '')) = 0
        OR LEN(ISNULL(t.Zip, '')) = 0
        OR LEN(ISNULL(t.Email, '')) = 0
    )
    AND gas.StatusID = 255;

    --ALL OTHERS
    UPDATE gas
    SET
        gas.StatusID = 1,
        gas.Update_Tms = GETDATE(),
        gas.Comments = ISNULL(@Notes, '') + '|Check Account:' + CAST(tc.Account_ID AS VARCHAR(MAX)) + '|'
    OUTPUT
        Inserted.AccountId,
        270 AS CarrierID,
        Deleted.StatusID,
        Inserted.StatusID
    INTO
        Logs.tblAccountStoreLogs
        (
            AccountID,
            CarrierID,
            OldStatusID,
            NewStatusID
        )
    FROM CarrierSetup.tblGenmobileAccountStore AS gas
    JOIN #ToCheck AS t
        ON gas.AccountId = t.Account_ID
    LEFT JOIN #Base AS tc
        ON (
            (
                t.Address1 = tc.Address1
                OR LEFT(t.DBA, LEN(t.DBA) * 0.7) = LEFT(tc.DBA, LEN(tc.DBA) * 0.7)
            )
            AND t.Zip = tc.Zip
        )
        OR t.Email = tc.Email
        OR t.Phone = tc.Phone
        OR t.TaxID = tc.TaxID
    WHERE (
        tc.Account_ID IS NOT NULL
        OR LEN(ISNULL(t.Address1, '')) = 0
        OR LEN(ISNULL(t.DBA, '')) = 0
        OR LEN(ISNULL(t.TaxID, '')) = 0
        OR LEN(ISNULL(t.Zip, '')) = 0
        OR LEN(ISNULL(t.Email, '')) = 0
    )
    AND gas.StatusID = 255;

    UPDATE gas
    SET
        gas.StatusID = 1,
        gas.Update_Tms = GETDATE(),
        gas.Comments = ISNULL(@Notes, '') + '|Check Account:' + CAST(tc.Account_ID AS VARCHAR(MAX)) + '|'
    OUTPUT
        Inserted.AccountId,
        270 AS CarrierID,
        Deleted.StatusID,
        Inserted.StatusID
    INTO
        Logs.tblAccountStoreLogs
        (
            AccountID,
            CarrierID,
            OldStatusID,
            NewStatusID
        )
    FROM CarrierSetup.tblGenmobileAccountStore AS gas
    JOIN #ToCheck AS tc
        ON gas.AccountId = tc.Account_ID
    JOIN Account.tblAccountLink AS al
        ON al.AccountID = tc.Account_ID
    JOIN Account.tblAccountLink AS lk
        ON
            lk.LinkedID = al.LinkedID
            AND lk.AccountID <> tc.Account_ID
    JOIN CarrierSetup.tblGenmobileAccountStore AS gas2
        ON
            gas2.AccountId = lk.AccountID
            AND gas2.StatusID <> 255
    WHERE gas.StatusID = 255;

    UPDATE gas
    SET
        gas.StatusID = 1,
        gas.Update_Tms = GETDATE()
    OUTPUT
        Inserted.AccountId,
        270 AS CarrierID,
        Deleted.StatusID,
        Inserted.StatusID
    INTO
        Logs.tblAccountStoreLogs
        (
            AccountID,
            CarrierID,
            OldStatusID,
            NewStatusID
        )
    FROM CarrierSetup.tblGenmobileAccountStore AS gas
    JOIN #ListOfAccounts AS la
        ON la.AccountID = gas.AccountId
    WHERE
        gas.StatusID = 255
        AND la.info = '';

    UPDATE la
    SET la.info = gass.Description
    FROM #ListOfAccounts AS la
    JOIN CarrierSetup.tblGenmobileAccountStore AS gas
        ON
            la.AccountID = gas.AccountId
            AND gas.StatusID <> 255
    JOIN CarrierSetup.tblAccountStoreStatus AS gass
        ON gass.StatusID = gas.StatusID
    WHERE la.info = '';

    SELECT
        la.AccountID,
        gas.GMStoreId,
        la.info AS [Description],
        gas.Comments,
        gas.TotalMonthlyActivation,
        gas.GMMonthlyActivationForecast,
        gas.PrefLang
    FROM #ListOfAccounts AS la
    LEFT JOIN CarrierSetup.tblGenmobileAccountStore AS gas
        ON
            la.AccountID = gas.AccountId
            AND gas.StatusID <> 255;

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
    RETURN;
END CATCH;
