-- liquibase formatted sql

-- changeset jrose:42B02F45-CD35-4AE4-8C34-BC776E1D366C stripComments:false runOnChange:true endDelimiter:/
-- =============================================
--             : 
--      Author : John Rose
--             : 
--     Created : 2024-02-29
--             : 
--       Usage : EXEC [Billing].[P_UpdateDatedueOfUnpaidCommissions] '1097704897, 1096998580, 1087571742', '2024-04-10', 1 
--             : 
-- Description : Updates the Datedue in the Order_Commission table given a list 
--             : of primary keys (Order_Commission_SK).
--             : 
-- =============================================
CREATE PROCEDURE [Billing].[P_UpdateDatedueOfUnpaidCommissions]
    (
        @OrderCommissionSKs NVARCHAR(MAX),
        @NewDatedue DATE = NULL,
        @Command INT = 0 -- 0 : List, 1 : Update
    )
AS
BEGIN

    IF @OrderCommissionSKs = '' OR @OrderCommissionSKs IS NULL
        BEGIN
            SELECT 'A list of commission SK''s is required in all cases.' AS [Error Message]
            RETURN;
        END

    IF @Command = 0 -- List
        BEGIN
            SELECT
                oc.Order_Commission_SK,
                oc.Order_No,
                oc.Orders_ID,
                oc.Account_ID,
                ac.Account_Name,
                oc.Commission_Amt,
                oc.Datedue,

                @NewDatedue AS [New Date Due]

            FROM [dbo].[Order_Commission] AS oc WITH (NOLOCK)
            JOIN [dbo].[Account] AS ac WITH (NOLOCK) ON oc.Account_ID = ac.Account_ID

            WHERE oc.Order_Commission_SK IN (SELECT ID FROM dbo.[fnSplitterToString](@OrderCommissionSKs))

            ORDER BY oc.Order_Commission_SK;
        END;

    IF @Command = 1 -- Update
        BEGIN

            IF @NewDatedue < CAST(GETDATE() AS DATE)
                BEGIN
                    SELECT 'A Date Due can not be back dated. Please try again.' AS [Error Message]
                    RETURN;
                END

            UPDATE CellDay_Prod.dbo.Order_Commission
            SET Datedue = CAST(@NewDatedue AS DATE)
            WHERE Order_Commission_SK IN (SELECT ID FROM dbo.[fnSplitterToString](@OrderCommissionSKs))

            SELECT
                oc.Order_Commission_SK,
                oc.Order_No,
                oc.Orders_ID,
                oc.Account_ID,
                ac.Account_Name,
                oc.Commission_Amt,

                oc.Datedue AS [New Date Due]

            FROM [dbo].[Order_Commission] AS oc WITH (NOLOCK)

            JOIN [dbo].[Account] AS ac WITH (NOLOCK)
                ON
                    oc.Account_ID = ac.Account_ID

            JOIN Order_No AS od WITH (NOLOCK)
                ON
                    oc.Order_No = od.Order_No

            WHERE oc.Order_Commission_SK IN (SELECT ID FROM dbo.[fnSplitterToString](@OrderCommissionSKs))

            ORDER BY oc.Order_Commission_SK;

        END;

END;
-- noqa: disable=all
/